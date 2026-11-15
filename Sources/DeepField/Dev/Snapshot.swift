import AppKit
import Metal

/// Renders one frame offscreen and saves it as a PNG, upscaled with nearest-neighbor like the
/// live wallpaper. Deterministic for a given config, size and time (events use seed 1).
enum Snapshot {
    static func render(to path: String, config: WallpaperConfig, size: (width: Int, height: Int),
                       time: Double, eventsEnabled: Bool) {
        let px = config.pixelSize
        let w = (size.width + px - 1) / px, h = (size.height + px - 1) / px

        let r = Renderer.shared
        guard let baked = r.bake(width: w, height: h, config: config, wait: false),
              let target = r.makeTexture(.bgra8Unorm, w, h, usage: [.renderTarget, .shaderRead]),
              let cb = r.queue.makeCommandBuffer() else { exit(1) }
        let events = EventSchedule(seed: 1, enabled: eventsEnabled)
        r.encodeFrame(cb, target: target, baked: baked, elapsed: time, config: config, events: events)

        let rowBytes = w * 4
        let buffer = r.device.makeBuffer(length: rowBytes * h, options: .storageModeShared)!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // nearest-neighbor upscale on the CPU (BGRA)
        let src = buffer.contents().bindMemory(to: UInt32.self, capacity: w * h)
        let W = size.width, H = size.height
        var out = [UInt32](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W { out[y * W + x] = src[(y / px) * w + (x / px)] } }
        let data = Data(bytes: out, count: out.count * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                          provider: CGDataProvider(data: data as CFData)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let rep = NSBitmapImageRep(cgImage: img)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
