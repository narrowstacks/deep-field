import AppKit

/// Opt-in (`WallpaperConfig.lockScreenStill`): keeps a full-color still of the current scene as
/// each screen's desktop picture, so the lock screen and the login screen, which show the
/// desktop picture instead of our window, match the animated wallpaper.
///
/// Before replacing a screen's picture it remembers the original (URL and options, keyed by
/// display UUID) and puts it back when the setting is turned off. The still is re-rendered,
/// debounced, when the look of the scene changes and when screens change; a screen whose
/// picture the user has since changed is left alone until they press "Set now". Quitting the
/// app leaves the still in place, which is the point.
final class LockScreenStill: ObservableObject {
    static let shared = LockScreenStill()

    /// One line for the System section: what was last done, or what went wrong.
    @Published private(set) var status = ""
    /// A render is in flight.
    @Published private(set) var busy = false

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Deep Field/Lock Screen", isDirectory: true)

    /// Rendering is capped at about this many shaded pixels (larger screens render at half or a
    /// third of their resolution and are scaled up smoothly), which keeps the transient bake
    /// under roughly 0.5 GB for the black hole.
    static let maxShadedPixels = 6_000_000.0

    private let defaults = UserDefaults.standard
    private let originalsKey = "lockScreenStillOriginals"   // display UUID -> archived picture
    private let currentKey = "lockScreenStillCurrent"       // display UUID -> path of our still
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var generation = 0
    private var wasEnabled = false
    private var lastLook: WallpaperConfig?
    private var lastScreens: [String: [Int]] = [:]

    private var config: WallpaperConfig { ConfigStore.shared.config }
    var isEnabled: Bool { config.lockScreenStill }

    func start() {
        guard observers.isEmpty else { return }
        wasEnabled = isEnabled
        lastLook = Self.look(config)
        lastScreens = Self.screenSignature()
        observers.append(NotificationCenter.default.addObserver(
            forName: ConfigStore.changed, object: nil, queue: .main) { [weak self] _ in self?.configChanged() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() })
        // catch up with changes made while the app wasn't running (a new display, a new build)
        if isEnabled { scheduleRefresh(after: 2) } else { restore() }
    }

    /// "Set now": renders and applies to every screen, including ones whose picture the user
    /// changed since our last refresh.
    func setNow() { refresh(force: true) }

    // MARK: triggers

    private func configChanged() {
        let c = config
        if c.lockScreenStill != wasEnabled {
            wasEnabled = c.lockScreenStill
            lastLook = Self.look(c)
            if wasEnabled { refresh(force: true) } else { cancel(); restore() }
            return
        }
        guard wasEnabled, Self.look(c) != lastLook else { return }
        lastLook = Self.look(c)
        scheduleRefresh(after: 3)
    }

    private func screensChanged() {
        let sig = Self.screenSignature()
        guard sig != lastScreens else { return }
        lastScreens = sig
        // when off, a display that was detached at the time gets its picture back now
        if isEnabled { scheduleRefresh(after: 3) } else { restore() }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(force: false) }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancel() {
        refreshWork?.cancel()
        generation += 1   // drops renders still in flight
        busy = false
    }

    // MARK: rendering

    /// What the still depends on: the config minus settings that don't change it (frame rate;
    /// in smooth mode also the pixel look, which stillConfig overrides).
    private static func look(_ c: WallpaperConfig) -> WallpaperConfig {
        var c = stillConfig(c)
        c.fps = 24
        c.lockScreenStill = false
        return c
    }

    /// Dithered (default): exactly the wallpaper's pixel size, color levels and dither pattern.
    /// Smooth: no coarse pixels and 256 levels (the fine Bayer dither then only breaks up banding).
    static func stillConfig(_ c: WallpaperConfig) -> WallpaperConfig {
        guard c.lockScreenSmooth else { return c }
        var c = c
        c.pixelSize = 1
        c.levels = 256
        c.dither = .bayer8
        return c
    }

    /// A moment where each scene looks like itself (events are off anyway).
    static func representativeTime(_ c: WallpaperConfig) -> Double {
        switch c.scene {
        case .blackHole: 444
        case .tidalDisruption: 0.55 * c.tdeCycleMinutes * 60     // the stream wrapping round the hole
        case .pulsar: 20 * c.pulsarPeriod                         // whole turns: beams on the diagonals
        case .binary: 0.72 * c.starOrbitMinutes * 60              // both stars clear of each other
        case .trinary: 0.33 * c.starOrbitMinutes * 60
        default: 130                                              // star close-up: between eruptions
        }
    }

    private static let leftAlone = "Not updated: you chose another desktop picture. Use Set now to replace it."

    private struct Target { let key: String; let width: Int; let height: Int }

    private func refresh(force: Bool) {
        refreshWork?.cancel()
        guard isEnabled else { return }
        generation += 1
        let gen = generation
        let originals = loadOriginals()
        var skipped = 0
        let targets: [Target] = NSScreen.screens.compactMap { screen in
            guard let key = Self.displayKey(screen) else { return nil }
            // the user picked another picture since we last set ours: leave it unless forced
            if !force, originals[key] != nil, !isOurs(NSWorkspace.shared.desktopImageURL(for: screen)) {
                skipped += 1
                return nil
            }
            let (w, h) = Self.nativePixelSize(screen)
            return Target(key: key, width: w, height: h)
        }
        if targets.isEmpty {
            // the new generation dropped any render in flight, so nothing else will end it
            busy = false
            status = skipped > 0 ? Self.leftAlone : "Not updated: no display is available."
            return
        }
        busy = true
        let c = Self.stillConfig(config)
        render(targets[...], config: c, time: Self.representativeTime(c), force: force, generation: gen,
               applied: 0, skipped: skipped)
    }

    /// One screen at a time, so only one full-resolution bake is alive at once.
    private func render(_ targets: ArraySlice<Target>, config c: WallpaperConfig, time: Double, force: Bool,
                        generation gen: Int, applied: Int, skipped: Int) {
        guard let t = targets.first else {
            busy = false
            cleanUp()
            let when = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            var s = "Set on \(applied) display\(applied == 1 ? "" : "s") at \(when)."
            if skipped > 0 { s += " Left \(skipped) with a picture you chose." }
            if applied > 0 { status = s }   // else it already says why the last display failed
            return
        }
        // dithered: shade one pixel per wallpaper cell and blow it up with crisp edges, like the
        // live wallpaper; smooth: shade at (up to) native resolution
        let dithered = !c.lockScreenSmooth
        let factor = dithered ? max(1, c.pixelSize)
            : max(1, Int((Double(t.width * t.height) / Self.maxShadedPixels).squareRoot().rounded(.up)))
        let w = (t.width + factor - 1) / factor, h = (t.height + factor - 1) / factor
        let url = Self.folder.appendingPathComponent("\(t.key)-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        let t0 = CFAbsoluteTimeGetCurrent()
        FrameCapture.render(config: c, width: w, height: h, time: time, eventsEnabled: false) { frame in
            DispatchQueue.global(qos: .utility).async {
                var error: String?
                if let frame, let image = FrameCapture.upscaled(frame, factor: factor, width: t.width, height: t.height, nearest: dithered) {
                    do {
                        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                        try FrameCapture.writePNG(image, to: url)
                    } catch let e { error = e.localizedDescription }
                } else {
                    error = "rendering failed"
                }
                DispatchQueue.main.async {
                    guard gen == self.generation, self.isEnabled else {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    if Settings.debug {
                        NSLog("DeepField: lock screen still %dx%d (shaded %dx%d) in %.0f ms", t.width, t.height, w, h,
                              (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    }
                    var ok = false
                    if let error {
                        self.status = "Couldn't make the still: \(error)"
                    } else {
                        ok = self.apply(url, to: t.key, force: force)
                    }
                    if !ok { try? FileManager.default.removeItem(at: url) }
                    self.render(targets.dropFirst(), config: c, time: time, force: force, generation: gen,
                                applied: applied + (ok ? 1 : 0), skipped: skipped)
                }
            }
        }
    }

    // MARK: desktop pictures

    private static let stillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
        .fillColor: NSColor.black,
    ]

    /// Sets our still on the display `key`, first remembering the picture it replaces.
    private func apply(_ url: URL, to key: String, force: Bool) -> Bool {
        guard let screen = Self.screen(for: key) else {
            status = "Not updated: the display was disconnected."
            return false
        }
        let ws = NSWorkspace.shared
        var originals = loadOriginals()
        let previous = ws.desktopImageURL(for: screen)
        var recorded = false
        if !isOurs(previous) {
            if originals[key] != nil && !force {   // changed by the user mid-render
                status = Self.leftAlone
                return false
            }
            originals[key] = Picture(url: previous, options: ws.desktopImageOptions(for: screen) ?? [:])
            saveOriginals(originals)
            recorded = true
        }
        do {
            try ws.setDesktopImageURL(url, for: screen, options: Self.stillOptions)
        } catch {
            if recorded { originals[key] = nil; saveOriginals(originals) }
            status = "Couldn't set the desktop picture: \(error.localizedDescription)"
            return false
        }
        var current = defaults.dictionary(forKey: currentKey) as? [String: String] ?? [:]
        current[key] = url.path
        defaults.set(current, forKey: currentKey)
        return true
    }

    /// Puts back the remembered pictures of attached displays. Displays that aren't attached
    /// keep their records and are restored when they come back (while the setting is off).
    private func restore() {
        var originals = loadOriginals()
        var current = defaults.dictionary(forKey: currentKey) as? [String: String] ?? [:]
        guard !originals.isEmpty || !current.isEmpty else { return }
        let ws = NSWorkspace.shared
        var problems: [String] = []
        for (key, original) in originals {
            guard let screen = Self.screen(for: key) else { continue }
            if isOurs(ws.desktopImageURL(for: screen)) {
                // the original may have been deleted or be on a disk that isn't mounted
                let target = original.url.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil }
                    ?? Self.defaultDesktopPicture
                guard let target else {
                    problems.append("\(screen.localizedName): the original picture is gone; the still stays")
                    originals[key] = nil
                    continue   // keeps current[key], so the still's file isn't deleted from under it
                }
                do {
                    try ws.setDesktopImageURL(target, for: screen, options: target == original.url ? original.options : [:])
                    if target != original.url { problems.append("\(screen.localizedName): the original picture is gone; set the macOS default") }
                } catch {
                    problems.append("\(screen.localizedName): \(error.localizedDescription)")
                    continue
                }
            }
            // if the picture isn't ours any more, the user replaced it: nothing to restore
            originals[key] = nil
            current[key] = nil
        }
        // still files of displays that have no record left and aren't attached are dropped too
        for key in current.keys where originals[key] == nil && Self.screen(for: key) == nil { current[key] = nil }
        saveOriginals(originals)
        defaults.set(current, forKey: currentKey)
        cleanUp()
        status = problems.isEmpty ? "Restored your desktop picture." : problems.joined(separator: ". ") + "."
    }

    /// Deletes stills no display uses any more.
    private func cleanUp() {
        let current = defaults.dictionary(forKey: currentKey) as? [String: String] ?? [:]
        let keep = Set(current.values.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "png" && !keep.contains(f.standardizedFileURL.path) {
            try? fm.removeItem(at: f)
        }
    }

    private func isOurs(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.standardizedFileURL.deletingLastPathComponent().path == Self.folder.standardizedFileURL.path
    }

    private static let defaultDesktopPicture: URL? = ["/System/Library/CoreServices/DefaultDesktop.heic",
                                                      "/System/Library/CoreServices/DefaultDesktop.jpg"]
        .first { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }

    // MARK: persistence

    struct Picture {
        var url: URL?
        var options: [NSWorkspace.DesktopImageOptionKey: Any]
    }

    func loadOriginals() -> [String: Picture] {
        guard let saved = defaults.dictionary(forKey: originalsKey) as? [String: Data] else { return [:] }
        let classes = [NSDictionary.self, NSString.self, NSNumber.self, NSColor.self, NSURL.self]
        return saved.compactMapValues { data in
            guard let d = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [String: Any] else { return nil }
            let opts = (d["options"] as? [String: Any] ?? [:])
            return Picture(url: (d["url"] as? String).flatMap(URL.init(string:)),
                           options: Dictionary(uniqueKeysWithValues: opts.map { (NSWorkspace.DesktopImageOptionKey(rawValue: $0.key), $0.value) }))
        }
    }

    private func saveOriginals(_ originals: [String: Picture]) {
        let saved = originals.compactMapValues { p -> Data? in
            var d: [String: Any] = ["options": Dictionary(uniqueKeysWithValues: p.options.map { ($0.key.rawValue, $0.value) })]
            if let url = p.url { d["url"] = url.absoluteString }
            return try? NSKeyedArchiver.archivedData(withRootObject: d as NSDictionary, requiringSecureCoding: true)
        }
        defaults.set(saved, forKey: originalsKey)
    }

    // MARK: displays

    /// Stable across reboots and ports, unlike the CGDirectDisplayID.
    static func displayKey(_ screen: NSScreen) -> String? {
        guard let id = WallpaperWindow.displayID(of: screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(for key: String) -> NSScreen? {
        NSScreen.screens.first { displayKey($0) == key }
    }

    private static func screenSignature() -> [String: [Int]] {
        var sig: [String: [Int]] = [:]
        for s in NSScreen.screens {
            if let key = displayKey(s) { let (w, h) = nativePixelSize(s); sig[key] = [w, h] }
        }
        return sig
    }

    /// The panel's native pixel size when the current mode has the same shape (it may be a
    /// scaled "looks like" mode), else the backing size.
    static func nativePixelSize(_ screen: NSScreen) -> (Int, Int) {
        let backing = (Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                       Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        let nativeFlag: UInt32 = 0x0200_0000   // kDisplayModeNativeFlag
        guard let id = WallpaperWindow.displayID(of: screen),
              let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary)
                as? [CGDisplayMode],
              let native = modes.filter({ $0.ioFlags & nativeFlag != 0 }).max(by: { $0.pixelWidth < $1.pixelWidth })
        else { return backing }
        let aspect = Double(backing.0) / Double(backing.1)
        let nativeAspect = Double(native.pixelWidth) / Double(native.pixelHeight)
        return abs(aspect - nativeAspect) < 0.01 ? (native.pixelWidth, native.pixelHeight) : backing
    }
}
