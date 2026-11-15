import AppKit

extension CustomizeWindowController {
    /// Dev aid: `--capture-ui out.png` opens the window, saves an image of it, and quits.
    /// `-captureTab N` picks the tab and `-captureScene name` the scene (not saved).
    func captureForDebug(to path: String) {
        if let name = UserDefaults.standard.string(forKey: "captureScene"), let scene = SceneKind(rawValue: name) {
            ConfigStore.shared.persists = false
            ConfigStore.shared.config.scene = scene
        }
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let view = self?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
