import AppKit
import SwiftUI

/// Small baked stills of every listed scene with the current settings, for the scene gallery.
/// Each is rendered at one shaded pixel per point, so shown 1:1 with nearest-neighbor it has
/// the wallpaper's dither look. Offscreen stills, not live views: the window keeps exactly one
/// live renderer.
final class SceneThumbnails: ObservableObject {
    @Published private(set) var images: [SceneKind: CGImage] = [:]
    /// The size in pixels of the window's screen, which the preview renders. Kept here alone, so
    /// the preview, its caption and the gallery can't disagree. The main screen's until `follow`.
    @Published private(set) var reference: CGSize
    var size: (width: Int, height: Int) { Self.size(for: reference) }

    static func size(for reference: CGSize) -> (width: Int, height: Int) {
        let s = Theme.fit(reference, in: Theme.gallery(for: reference).box)
        return (max(16, Int(s.width.rounded())), max(16, Int(s.height.rounded())))
    }

    private var rendered: [SceneKind: WallpaperConfig.StillSettings] = [:]
    private var generation: [SceneKind: Int] = [:]
    private var observer: NSObjectProtocol?
    private var work: DispatchWorkItem?
    private var screenObservers: [NSObjectProtocol] = []
    private var screenWork: DispatchWorkItem?

    init() {
        reference = NSScreen.main.map(Self.pixels) ?? CGSize(width: 2880, height: 1800)
    }

    deinit {
        stop()
        screenObservers.forEach(NotificationCenter.default.removeObserver)
        screenWork?.cancel()
    }

    private static func pixels(of s: NSScreen) -> CGSize {
        CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
    }

    /// Keeps `reference` to the screen `window` is on, not `NSScreen.main`, which follows the
    /// keyboard focus. Called once the window is placed, so it opens at the right size.
    func follow(_ window: NSWindow) {
        updateReference(window)
        // occlusion too: a minimized or hidden window may have no screen until it's back
        let sources: [(Notification.Name, Any?)] = [
            (NSWindow.didChangeScreenNotification, window),
            (NSWindow.didChangeOcclusionStateNotification, window),
            (NSApplication.didChangeScreenParametersNotification, nil),
        ]
        screenObservers = sources.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self, weak window] _ in
                if let window { self?.scheduleReference(window) }
            }
        }
    }

    /// Debounced, and held until the mouse is up, so a drag across displays changes it once.
    private func scheduleReference(_ window: NSWindow) {
        screenWork?.cancel()
        let w = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleReference(window) } else { self.updateReference(window) }
        }
        screenWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func updateReference(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        let new = Self.pixels(of: screen), oldSize = size
        guard new != reference else { return }
        reference = new
        // thumbnails often keep their size (same shape, other scale); hidden ones wait for `start`
        guard size != oldSize else { return }
        rendered = [:]
        if observer != nil { refresh() }
    }

    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: ConfigStore.changed, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() }
        }
        refresh()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        work?.cancel()
        work = nil
    }

    /// Debounced, so dragging a slider re-renders once it settles.
    private func scheduleRefresh() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// The settings a still of `kind` is drawn with.
    private func config(for kind: SceneKind) -> WallpaperConfig {
        var c = ConfigStore.shared.config
        c.scene = kind
        c.phoneFraming = nil
        c.pixelSize = 1
        return c
    }

    /// A gallery still of `c`. It shows no events started by hand (Show Me): those belong to the
    /// live views, and one running at the still's moment would stay until the next re-render.
    static func render(_ c: WallpaperConfig, width: Int, height: Int, completion: @escaping (CGImage?) -> Void) {
        FrameCapture.render(config: c, width: width, height: height, time: 300, eventsEnabled: false, demo: [:],
                            completion: completion)
    }

    private func refresh() {
        let settings = ConfigStore.shared.config.stillSettings(SceneKind.listed, at: Date())
        for kind in SceneKind.listed {
            if let new = settings[kind], rendered[kind] == new { continue }
            rendered[kind] = settings[kind]
            let gen = (generation[kind] ?? 0) + 1
            generation[kind] = gen
            Self.render(config(for: kind), width: size.width, height: size.height) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.generation[kind] == gen else { return }
                    // a failed render stays due at the next refresh
                    if let image { self.images[kind] = image } else { self.rendered[kind] = nil }
                }
            }
        }
    }
}
