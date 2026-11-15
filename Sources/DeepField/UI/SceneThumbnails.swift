import AppKit
import SwiftUI

/// Small baked stills of every listed scene with the current settings, for the scene gallery.
/// Each is rendered at one shaded pixel per point, so shown 1:1 with nearest-neighbor it has
/// the wallpaper's dither look. Offscreen stills, not live views: the window keeps exactly one
/// live renderer.
final class SceneThumbnails: ObservableObject {
    @Published private(set) var images: [SceneKind: CGImage] = [:]
    let size: (width: Int, height: Int)

    private var rendered: [SceneKind: WallpaperConfig] = [:]
    private var generation: [SceneKind: Int] = [:]
    private var observer: NSObjectProtocol?
    private var work: DispatchWorkItem?

    init(reference: CGSize) {
        let s = Theme.fit(reference, in: Theme.gallery(for: reference).box)
        size = (max(16, Int(s.width.rounded())), max(16, Int(s.height.rounded())))
    }

    deinit { stop() }

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

    /// The settings a still of `kind` depends on. Fields that can't change a still are pinned,
    /// so changing them doesn't re-render anything.
    private func config(for kind: SceneKind) -> WallpaperConfig {
        var c = ConfigStore.shared.config
        c.scene = kind
        c.phoneFraming = nil
        c.pixelSize = 1
        c.fps = 24
        c.lockScreenStill = false
        c.lockScreenSmooth = false
        return c
    }

    private func refresh() {
        for kind in SceneKind.listed {
            let c = config(for: kind)
            if rendered[kind] == c { continue }
            rendered[kind] = c
            let gen = (generation[kind] ?? 0) + 1
            generation[kind] = gen
            FrameCapture.render(config: c, width: size.width, height: size.height, time: 300, eventsEnabled: false) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.generation[kind] == gen, let image else { return }
                    self.images[kind] = image
                }
            }
        }
    }
}
