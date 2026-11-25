import CoreGraphics
import Foundation

/// Part of `--check-customization`: a gallery thumbnail leaves out events started by hand (Show
/// Me), even one running at the thumbnail's moment, since it would stay until the next re-render.
/// Renders a few small stills offscreen; the started events live only in memory and are put back.
enum ThumbnailCheck {
    static func failures() -> [String] {
        var failures: [String] = []
        let store = ConfigStore.shared
        store.persists = false   // only demoEvents change here, which never save; this makes sure
        let before = store.demoEvents
        defer { store.demoEvents = before }
        let w = 160, h = 90, time = 300.0
        let cases: [(SceneKind, EventSchedule.Kind)] = [(.quasar, EventSchedule.quasarFlare),
                                                         (.gasGiant, EventSchedule.cometImpact),
                                                         (.ringedPlanet, EventSchedule.whiteStorm)]
        for (scene, kind) in cases {
            var c = WallpaperConfig()
            c.scene = scene
            c.pixelSize = 1
            let demo = [kind.id: time - 10]
            guard let plain = FrameCapture.render(config: c, width: w, height: h, time: time, eventsEnabled: false, demo: [:]),
                  let shown = FrameCapture.render(config: c, width: w, height: h, time: time, eventsEnabled: false, demo: demo) else {
                failures.append("\(scene.rawValue) didn't render")
                continue
            }
            // the event has to show at that moment, or the thumbnail's match below proves nothing
            if pixels(plain) == pixels(shown) { failures.append("event \(kind.id) doesn't show in \(scene.rawValue) at \(time) s") }
            store.demoEvents = demo
            let thumb = thumbnail(c, width: w, height: h)
            store.demoEvents = before
            if thumb.flatMap(pixels) != pixels(plain) {
                failures.append("\(scene.rawValue)'s thumbnail showed event \(kind.id), started by hand")
            }
        }
        return failures
    }

    /// Waits for the gallery's own render (encoded here on the main thread, finished on Metal's).
    private static func thumbnail(_ c: WallpaperConfig, width: Int, height: Int) -> CGImage? {
        var image: CGImage?
        let done = DispatchSemaphore(value: 0)
        SceneThumbnails.render(c, width: width, height: height) { image = $0; done.signal() }
        done.wait()
        return image
    }

    private static func pixels(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
