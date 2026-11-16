import Foundation

/// Renders one frame offscreen and saves it as a PNG, upscaled with nearest-neighbor like the
/// live wallpaper. Deterministic for a given config, size and time (events use seed 1).
enum Snapshot {
    static func render(to path: String, config: WallpaperConfig, size: (width: Int, height: Int),
                       time: Double, eventsEnabled: Bool, transition: FrameCapture.Transition? = nil) {
        let px = config.pixelSize
        let w = (size.width + px - 1) / px, h = (size.height + px - 1) / px
        guard let frame = FrameCapture.render(config: config, width: w, height: h, time: time, eventsEnabled: eventsEnabled,
                                               transition: transition),
              let image = FrameCapture.upscaled(frame, factor: px, width: size.width, height: size.height, nearest: true)
        else { exit(1) }
        do {
            try FrameCapture.writePNG(image, to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write("Could not write \(path): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
