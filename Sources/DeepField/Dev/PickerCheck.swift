import AppKit

/// `--check-picker outdir -captureTab 0`: opens the Customize window on the Scene section, whose
/// Colors group holds the scene's pickers (without the wallpaper windows, and without saving
/// anything), and for a few pickers does what NSColorPanel does when you pick a color: sets the
/// color well's color and sends its action.
/// Then it checks that the setting holds the pick, that the change notification went out, that
/// the live preview's next frame drew with it, and that a frame rendered from it differs from
/// the one before. Writes before/after snapshots to `outdir`. Exits 1 on any failure.
enum PickerCheck {
    private struct Case {
        let scene: SceneKind
        let name: String
        let kp: WritableKeyPath<WallpaperConfig, RGB>
        let pick: NSColor
    }

    static func runIfRequested() {
        let args = Arguments(CommandLine.arguments)
        guard let out = args.value("--check-picker") else { return }
        let store = ConfigStore.shared
        store.persists = false
        store.config = WallpaperConfig()

        var previewFrames: [WallpaperConfig] = []
        WallpaperView.debugRenderHook = { previewFrames.append($0) }
        var notifications = 0
        NotificationCenter.default.addObserver(forName: ConfigStore.changed, object: nil, queue: .main) { _ in
            notifications += 1
        }

        // the pastel pink comes in as Display P3, as the panel's color space may hand it over
        let cases = [
            Case(scene: .blackHole, name: "disk receding side", kp: \.palette.receding,
                 pick: NSColor(srgbRed: 1.0, green: 0.6, blue: 0.8, alpha: 1).usingColorSpace(.displayP3)!),
            Case(scene: .pulsar, name: "pulsar beams", kp: \.pulsarBeamColor,
                 pick: NSColor(srgbRed: 0.1, green: 0.85, blue: 0.2, alpha: 1)),
            Case(scene: .galaxy, name: "galaxy young stars", kp: \.palette.galaxyArms,
                 pick: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.1, alpha: 1)),
            Case(scene: .comet, name: "comet ion tail", kp: \.cometIonColor,
                 pick: NSColor(srgbRed: 1.0, green: 0.6, blue: 0.8, alpha: 1)),
        ]
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures += 1 }
        }
        func wells(_ v: NSView) -> [NSColorWell] {
            ((v as? NSColorWell).map { [$0] } ?? []) + v.subviews.flatMap(wells)
        }
        func close(_ a: NSColor, _ b: RGB) -> Bool {
            let x = RGB(a)
            return max(abs(x.r - b.r), abs(x.g - b.g), abs(x.b - b.b)) < 0.01
        }

        func run(_ i: Int) {
            guard i < cases.count else {
                print(failures == 0 ? "All picker checks passed" : "\(failures) picker checks failed")
                exit(failures == 0 ? 0 : 1)
            }
            let t = cases[i]
            store.config.scene = t.scene
            // let SwiftUI rebuild the section for the scene and the preview bake
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("\(t.name) (\(t.scene.rawValue))")
                let before = store.config
                guard let root = CustomizeWindowController.shared.window?.contentView,
                      let well = wells(root).first(where: { close($0.color, before[keyPath: t.kp]) }) else {
                    check(false, "found the color well showing the current color")
                    return run(i + 1)
                }
                check(true, "found the color well showing the current color")
                let n0 = notifications, f0 = previewFrames.count
                well.color = t.pick                      // what NSColorPanel does on a pick
                well.sendAction(well.action, to: well.target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let after = store.config
                    let want = RGB(t.pick)
                    let got = after[keyPath: t.kp]
                    check(close(t.pick, got), String(format: "setting holds the pick: (%.3f, %.3f, %.3f), picked (%.3f, %.3f, %.3f) sRGB",
                                                     got.r, got.g, got.b, want.r, want.g, want.b))
                    check(notifications > n0, "change notification posted (\(notifications - n0))")
                    let drawn = previewFrames.dropFirst(f0)
                    check(drawn.contains { close(t.pick, $0[keyPath: t.kp]) },
                          "live preview drew \(drawn.count) frames since, with the new color")
                    let size = (860, 360)
                    let time = 300.0
                    let a = FrameCapture.render(config: before, width: size.0, height: size.1, time: time, eventsEnabled: false)
                    let b = FrameCapture.render(config: after, width: size.0, height: size.1, time: time, eventsEnabled: false)
                    if let a, let b {
                        try? FrameCapture.writePNG(a, to: URL(fileURLWithPath: "\(out)/\(t.scene.rawValue)-before.png"))
                        try? FrameCapture.writePNG(b, to: URL(fileURLWithPath: "\(out)/\(t.scene.rawValue)-after.png"))
                        let changed = changedFraction(a, b)
                        check(changed > 0.005, String(format: "frame changed: %.1f%% of pixels", changed * 100))
                    } else {
                        check(false, "rendered frames")
                    }
                    run(i + 1)
                }
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        CustomizeWindowController.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(0) }
        app.run()
    }

    private static func changedFraction(_ a: CGImage, _ b: CGImage) -> Double {
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data?, da.count == db.count else { return 0 }
        var changed = 0
        da.withUnsafeBytes { pa in
            db.withUnsafeBytes { pb in
                for i in stride(from: 0, to: da.count, by: 4) where pa[i] != pb[i] || pa[i + 1] != pb[i + 1] || pa[i + 2] != pb[i + 2] {
                    changed += 1
                }
            }
        }
        return Double(changed) / Double(da.count / 4)
    }
}
