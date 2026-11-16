import AppKit
import Metal

/// Offscreen rendering of a single frame into a CGImage: bakes the scene at the given shaded
/// size, draws one frame, and reads it back. Used by `--snapshot` and the lock screen still.
enum FrameCapture {
    typealias Transition = (from: WallpaperConfig, progress: Double, style: TransitionStyle)

    /// Encodes and commits the bake, the frame and the readback. Call `image()` once `cb` has
    /// completed.
    private struct Pending {
        let cb: MTLCommandBuffer
        let buffer: MTLBuffer
        let width: Int, height: Int

        func image() -> CGImage? {
            let rowBytes = width * 4
            let data = Data(bytes: buffer.contents(), count: rowBytes * height)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                           decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// With `transition`, the frame is that far (0 to 1) into a schedule transition from `from`.
    private static func encode(config: WallpaperConfig, width w: Int, height h: Int, time: Double,
                               eventsEnabled: Bool, transition: Transition? = nil) -> Pending? {
        let r = Renderer.shared
        guard let cb = r.queue.makeCommandBuffer(),
              let target = r.makeTexture(.bgra8Unorm, w, h, usage: [.renderTarget, .shaderRead]),
              let buffer = r.device.makeBuffer(length: w * 4 * h, options: .storageModeShared) else { return nil }
        // the bake textures are only referenced by the command buffer, so they're freed with it
        guard let baked = r.encodeBake(cb, width: w, height: h, config: config) else { return nil }
        let events = EventSchedule(seed: 1, enabled: eventsEnabled)
        if let dissolve = transition {
            let usage: MTLTextureUsage = [.renderTarget, .shaderRead]
            guard let fromBaked = r.encodeBake(cb, width: w, height: h, config: dissolve.from),
                  let a = r.makeTexture(.bgra8Unorm, w, h, usage: usage),
                  let b = r.makeTexture(.bgra8Unorm, w, h, usage: usage) else { return nil }
            r.encodeFrame(cb, target: a, baked: fromBaked, elapsed: time, config: dissolve.from, events: events)
            r.encodeFrame(cb, target: b, baked: baked, elapsed: time, config: config, events: events)
            r.encodeTransition(cb, target: target, from: a, to: b, progress: dissolve.progress, seed: 1,
                               style: dissolve.style, fromConfig: dissolve.from, toConfig: config)
        } else {
            r.encodeFrame(cb, target: target, baked: baked, elapsed: time, config: config, events: events)
        }
        guard let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * 4 * h)
        blit.endEncoding()
        return Pending(cb: cb, buffer: buffer, width: w, height: h)
    }

    /// Renders one frame of `w` x `h` shaded pixels and waits for it.
    static func render(config: WallpaperConfig, width w: Int, height h: Int, time: Double,
                       eventsEnabled: Bool, transition: Transition? = nil) -> CGImage? {
        guard let p = encode(config: config, width: w, height: h, time: time, eventsEnabled: eventsEnabled,
                             transition: transition) else { return nil }
        p.cb.commit()
        p.cb.waitUntilCompleted()
        return p.cb.status == .completed ? p.image() : nil
    }

    /// Encodes on the calling thread (call it on the main thread, like the live views do) and
    /// calls `completion` on a Metal completion thread once the GPU is done.
    static func render(config: WallpaperConfig, width w: Int, height h: Int, time: Double,
                       eventsEnabled: Bool, completion: @escaping (CGImage?) -> Void) {
        guard let p = encode(config: config, width: w, height: h, time: time, eventsEnabled: eventsEnabled) else {
            completion(nil)
            return
        }
        p.cb.addCompletedHandler { cb in completion(cb.status == .completed ? p.image() : nil) }
        p.cb.commit()
    }

    /// Many frames of one config from a single bake (the phone loop). Encoding runs on the main
    /// thread, like the live views (the scene state caches aren't thread-safe); call `frame` from
    /// any thread, and it waits for the GPU there.
    final class Sequence {
        private let config: WallpaperConfig
        private let baked: Baked
        private let target: MTLTexture
        private let buffer: MTLBuffer
        private let width: Int, height: Int
        private let events = EventSchedule(seed: 1, enabled: false)

        init?(config: WallpaperConfig, width w: Int, height h: Int) {
            let r = Renderer.shared
            guard let target = r.makeTexture(.bgra8Unorm, w, h, usage: [.renderTarget, .shaderRead]),
                  let buffer = r.device.makeBuffer(length: w * 4 * h, options: .storageModeShared),
                  let baked = onMain({ r.bake(width: w, height: h, config: config, wait: true) }) else { return nil }
            self.config = config
            self.baked = baked
            self.target = target
            self.buffer = buffer
            width = w
            height = h
        }

        /// The frame at `time`, with planets and star orbits held at `orbitTime`.
        func frame(time: Double, orbitTime: Double) -> CGImage? {
            let r = Renderer.shared
            let cb: MTLCommandBuffer? = onMain {
                guard let cb = r.queue.makeCommandBuffer() else { return nil }
                r.encodeFrame(cb, target: target, baked: baked, elapsed: time, config: config, events: events,
                              orbitTime: orbitTime)
                guard let blit = cb.makeBlitCommandEncoder() else { return nil }
                blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: width, height: height, depth: 1),
                          to: buffer, destinationOffset: 0, destinationBytesPerRow: width * 4,
                          destinationBytesPerImage: width * 4 * height)
                blit.endEncoding()
                cb.commit()
                return cb
            }
            guard let cb else { return nil }
            cb.waitUntilCompleted()
            guard cb.status == .completed else { return nil }
            return Pending(cb: cb, buffer: buffer, width: width, height: height).image()
        }
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    /// Scales `image` up by a whole `factor` and crops it to `width` x `height` from the top
    /// left (the shaded size is rounded up, so the last cells overhang). Nearest-neighbor keeps
    /// the dither cells crisp; otherwise it's smoothed with high-quality interpolation.
    static func upscaled(_ image: CGImage, factor: Int, width: Int, height: Int, nearest: Bool) -> CGImage? {
        if factor == 1 && image.width == width && image.height == height { return image }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = nearest ? .none : .high
        let sw = image.width * factor, sh = image.height * factor
        ctx.draw(image, in: CGRect(x: 0, y: height - sh, width: sw, height: sh))
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}
