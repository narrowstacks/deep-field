import AppKit

extension CustomizeWindowController {
    /// Dev aid: `--capture-ui out.png` opens the window, saves an image of it, and quits.
    /// `-captureTab N` picks the section (0 Scene, 1 Sky, 2 Image, 3 System, 4 Phone) and
    /// `-captureScene name` the scene (not saved), `-captureSize WxH` the window's size. `--defaults` shows the default settings
    /// instead of the saved ones (also not saved).
    func captureForDebug(to path: String) {
        if CommandLine.arguments.contains("--defaults") {
            ConfigStore.shared.persists = false
            ConfigStore.shared.config = WallpaperConfig()
        }
        if let name = UserDefaults.standard.string(forKey: "captureScene"), let scene = SceneKind(rawValue: name) {
            ConfigStore.shared.persists = false
            ConfigStore.shared.config.scene = scene
        }
        show()
        // `-captureSize WxH` resizes the window first, as dragging its corner would
        if let size = UserDefaults.standard.string(forKey: "captureSize")?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2 {
            window?.setContentSize(CGSize(width: size[0], height: size[1]))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let view = self?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
