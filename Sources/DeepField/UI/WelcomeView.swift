import AppKit
import SwiftUI

/// The first-launch guide. The desktop stays as it was until the last step's Set as Wallpaper,
/// so nothing changes under someone who only opened the app to look. Every step shows the
/// scene large, live, with the settings as they stand. Opened again later, with the scene already
/// on the desktop, its changes show there as they're made, and it says so.
struct WelcomeView: View {
    enum Step: Int, CaseIterable { case hello, scene, tweaks, finish }

    @ObservedObject private var store = ConfigStore.shared
    @StateObject private var thumbnails = SceneThumbnails(reference: CustomizeView.reference)
    @State private var step: Step
    @State private var launchAtLogin = LoginItem.isEnabled
    /// The lock screen choice, if one was made. It replaces the desktop picture, so it waits for
    /// the last step's button.
    @State private var lockScreenChoice: Bool?
    /// The settings as the guide opened, which the tweaks undo to.
    @State private var base = ConfigStore.shared.config
    /// The scene was already on the desktop as the guide opened.
    @State private var onDesktop = Settings.wallpaperEnabled && !Settings.capturingUI
    let finish: (_ setWallpaper: Bool) -> Void

    init(startAt: Step = .hello, finish: @escaping (_ setWallpaper: Bool) -> Void) {
        _step = State(initialValue: startAt)
        self.finish = finish
    }

    private static let previewBox = CGSize(width: 800, height: 500)
    private static let panelWidth: CGFloat = 330
    static let size = CGSize(width: previewBox.width + 48 + 1 + panelWidth + 48, height: 640)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                WelcomePreview(store: store, box: Self.previewBox)
                Text("Live preview of \(store.config.scene.title), as it will look on your desktop")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: Self.previewBox.width + 48)
            .frame(maxHeight: .infinity)
            .background(Theme.stageBackground)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                stepDots.padding(.bottom, 18)
                Group {
                    switch step {
                    case .hello: hello
                    case .scene: scenePicker
                    case .tweaks: tweaks
                    case .finish: finishStep
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                navigation
            }
            .padding(24)
            .frame(width: Self.panelWidth + 48)
            .frame(maxHeight: .infinity)
            .background(Theme.inspectorBackground)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .preferredColorScheme(.dark)
        .onAppear { thumbnails.start() }
        .onDisappear { thumbnails.stop() }
    }

    // MARK: steps

    private var hello: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Deep Field").font(.title.weight(.semibold))
            Text("Deep Field puts a moving space scene behind your windows: black holes, galaxies, auroras, ringed planets and more, drawn as dithered pixel art.")
            Text(onDesktop
                 ? "Take a minute to pick a scene and try a few looks. Changes show on your desktop as you make them."
                 : "Your desktop stays as it is for now. Take a minute to pick a scene and try a few looks, and set it as your wallpaper at the end if you like it.")
                .foregroundStyle(.secondary)
            Label("Afterwards, Deep Field lives in the menu bar.", systemImage: "circle.circle")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var scenePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a scene").font(.title2.weight(.semibold))
            Text(store.config.scene.blurb).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36, alignment: .topLeading)
            ScrollView {
                SceneGallery(store: store, thumbnails: thumbnails, columns: 2)
                    .padding(.vertical, 2)
            }
        }
    }

    private var tweaks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try a few looks").font(.title2.weight(.semibold))
            Text("Click to turn each one on or off and watch the preview. There are many more settings in Customize.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Tweak.all) { tweak in
                        TweakRow(tweak: tweak, on: tweak.isOn(store.config)) {
                            var c = store.config
                            if tweak.isOn(c) { tweak.turnOff(&c, base: base) } else { tweak.apply(&c) }
                            store.config = c
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Button("Undo All") {
                store.config = Tweak.undoingAll(store.config, to: base)
            }
            .disabled(Tweak.undoingAll(store.config, to: base) == store.config)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready when you are").font(.title2.weight(.semibold))
            Text(onDesktop
                 ? "\(store.config.scene.title) is on every display. You can change anything later from the menu bar icon, under Customize."
                 : "Set as Wallpaper puts \(store.config.scene.title) on every display. You can change anything later from the menu bar icon, under Customize.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open Deep Field when you log in", isOn: $launchAtLogin)
            Toggle("Show a still of this scene on the lock screen", isOn: Binding(
                get: { lockScreenChoice ?? store.config.lockScreenStill }, set: { lockScreenChoice = $0 }))
            Text("The lock screen can't animate, so it shows a still. Your own picture comes back if you turn this off.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: chrome

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Color.accentColor : Color.white.opacity(0.2))
                    .frame(width: s == step ? 18 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var navigation: some View {
        HStack {
            if step == .finish && !onDesktop {
                Button("Not Now") { done(false) }
                    .help("Close the guide without changing your desktop. Turn it on later from the menu bar icon.")
            } else if step != .hello {
                Button("Back") { move(-1) }
            }
            Spacer()
            if step == .finish {
                Button(onDesktop ? "Done" : "Set as Wallpaper") { done(true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .hello ? "Get Started" : "Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.top, 16)
    }

    private func move(_ by: Int) {
        if let s = Step(rawValue: step.rawValue + by) { step = s }
    }

    private func done(_ setWallpaper: Bool) {
        if setWallpaper {
            if launchAtLogin != LoginItem.isEnabled { LoginItem.setEnabled(launchAtLogin) }
            if let lockScreenChoice { store.config.lockScreenStill = lockScreenChoice }
        }
        // Done leaves Show on Desktop as it is, in case it was switched off meanwhile
        finish(setWallpaper && !onDesktop)
    }
}

/// One example tweak: a name, what it does, and how to turn it on and back off. Off puts the
/// fields it touches back to what they were when the guide opened.
struct Tweak: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let isOn: (WallpaperConfig) -> Bool
    let apply: (inout WallpaperConfig) -> Void
    let restore: (inout WallpaperConfig, WallpaperConfig) -> Void

    /// `base`, with the image settings it has for `c`'s scene in place.
    private static func base(_ base: WallpaperConfig, for c: WallpaperConfig) -> WallpaperConfig {
        var b = base
        b.scene = c.scene
        return b
    }

    /// Puts its fields back to `base`'s, or to the defaults when `base` had the tweak on already.
    func turnOff(_ c: inout WallpaperConfig, base: WallpaperConfig) {
        let b = Self.base(base, for: c)
        restore(&c, isOn(b) ? WallpaperConfig() : b)
    }

    static func undoingAll(_ c: WallpaperConfig, to base: WallpaperConfig) -> WallpaperConfig {
        let b = Self.base(base, for: c)
        var c = c
        all.forEach { $0.restore(&c, b) }
        return c
    }

    static let all: [Tweak] = {
        return [
            Tweak(id: "chunky", title: "Chunkier pixels", detail: "Twice the pixel size, more retro", symbol: "square.grid.3x3",
                  isOn: { $0.pixelSize >= 5 },
                  apply: { $0.pixelSize = 6 },
                  restore: { $0.pixelSize = $1.pixelSize }),
            Tweak(id: "smooth", title: "Smooth", detail: "Full resolution and many more colors", symbol: "drop",
                  isOn: { $0.pixelSize == 1 && $0.levels >= 32 },
                  apply: { $0.pixelSize = 1; $0.levels = 64 },
                  restore: { $0.pixelSize = $1.pixelSize; $0.levels = $1.levels }),
            Tweak(id: "retro", title: "Coarse dither", detail: "A 4×4 pattern and only three shades per color", symbol: "checkerboard.rectangle",
                  isOn: { $0.dither == .bayer4 && $0.levels <= 3 },
                  apply: { $0.dither = .bayer4; $0.levels = 3 },
                  restore: { $0.dither = $1.dither; $0.levels = $1.levels }),
            Tweak(id: "glow", title: "Glow", detail: "Bright parts bloom into the dark", symbol: "sparkles",
                  isOn: { $0.bloom >= 0.9 },
                  apply: { $0.bloom = 1.2 },
                  restore: { $0.bloom = $1.bloom }),
            Tweak(id: "vivid", title: "Vivid", detail: "Stronger color and a little more light", symbol: "paintpalette",
                  isOn: { $0.saturation >= 1.7 },
                  apply: { $0.saturation = 1.8; $0.brightness = 1.35 },
                  restore: { $0.saturation = $1.saturation; $0.brightness = $1.brightness }),
            Tweak(id: "moody", title: "Moody", detail: "More contrast and darker corners", symbol: "circle.lefthalf.filled",
                  isOn: { $0.vignette >= 0.4 },
                  apply: { $0.contrast = 1.3; $0.vignette = 0.55 },
                  restore: { $0.contrast = $1.contrast; $0.vignette = $1.vignette }),
            Tweak(id: "busy", title: "Busier sky", detail: "Supernovae, comets and twinkles more often", symbol: "star",
                  isOn: { $0.supernovae == .often },
                  apply: { $0.supernovae = .often; $0.comets = .often; $0.twinkles = .often },
                  restore: { $0.supernovae = $1.supernovae; $0.comets = $1.comets; $0.twinkles = $1.twinkles }),
        ]
    }()
}

private struct TweakRow: View {
    let tweak: Tweak
    let on: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tweak.symbol)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tweak.title).font(.body.weight(.medium))
                    Text(tweak.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(on ? 0.1 : (hovered ? 0.06 : 0.03))))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The large live preview, fitted to the main screen's shape. During a window capture (which
/// can't read a Metal layer) it shows a rendered still instead.
private struct WelcomePreview: View {
    @ObservedObject var store: ConfigStore
    let box: CGSize
    @State private var still: CGImage?

    var body: some View {
        let reference = CustomizeView.reference
        let fitted = Theme.fit(reference, in: box)
        return Group {
            if Settings.capturingUI {
                ZStack {
                    Color.black
                    if let still { Image(decorative: still, scale: 1).resizable().interpolation(.high) }
                }
                .onAppear { renderStill(reference) }
                .onChange(of: store.config) { renderStill(reference) }
            } else {
                LivePreview(reference: reference, actualPixels: false)
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
        .frame(width: box.width)
    }

    private func renderStill(_ reference: CGSize) {
        let px = CGFloat(store.config.pixelSize)
        let w = Int((reference.width / px).rounded(.up)), h = Int((reference.height / px).rounded(.up))
        still = FrameCapture.render(config: store.config, width: w, height: h, time: 300, eventsEnabled: false)
    }
}

/// The guide's window. Shown on first launch, and from the menu bar's Welcome Guide item.
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var onFinish: ((Bool) -> Void)?

    func show(startAt step: WelcomeView.Step = .hello, onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
        if window == nil {
            let view = WelcomeView(startAt: step) { [weak self] setWallpaper in self?.finish(setWallpaper) }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Welcome to Deep Field"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in self?.closed() }
            window = w
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ setWallpaper: Bool) {
        let callback = onFinish
        onFinish = nil
        window?.close()
        callback?(setWallpaper)
    }

    /// Closing the window counts as Not Now.
    private func closed() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        let w = window
        window = nil
        DispatchQueue.main.async { w?.contentViewController = nil }
        if let callback = onFinish {
            onFinish = nil
            callback(false)
        }
    }

    /// Dev aid: `--capture-welcome out.png -welcomeStep N` saves an image of step N and quits.
    func captureForDebug(to path: String, step: Int) {
        ConfigStore.shared.persists = false
        if CommandLine.arguments.contains("--defaults") { ConfigStore.shared.config = WallpaperConfig() }
        if let name = UserDefaults.standard.string(forKey: "captureScene"), let scene = SceneKind(rawValue: name) {
            ConfigStore.shared.config.scene = scene
        }
        if let tweaks = UserDefaults.standard.string(forKey: "captureTweaks") {
            var c = ConfigStore.shared.config
            for id in tweaks.split(separator: ",") { Tweak.all.first { $0.id == id }?.apply(&c) }
            ConfigStore.shared.config = c
        }
        show(startAt: WelcomeView.Step(rawValue: step) ?? .hello) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let view = self?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
