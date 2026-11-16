import Foundation
import ImageIO
import Metal

/// The Aurora scene's Earth at night: NASA's Black Marble city lights and the dim ground under
/// them, made by `Design/Earth/make_earth_maps.py`. Loaded on first use and kept, since they're
/// the same for every screen (about 25 MB of GPU memory with mipmaps).
enum EarthMaps {
    struct Textures {
        let lights: MTLTexture
        let ground: MTLTexture
    }

    private static let lock = NSLock()
    private static var loaded: Textures?
    private static var tried = false

    /// nil when the map files can't be found (the scene then draws a made-up Earth).
    static func textures(_ device: MTLDevice, _ queue: MTLCommandQueue) -> Textures? {
        lock.lock()
        defer { lock.unlock() }
        if !tried {
            tried = true
            if let dir = directory(),
               let lights = load(dir.appendingPathComponent("night-lights.png"), device, queue),
               let ground = load(dir.appendingPathComponent("night-ground.png"), device, queue) {
                loaded = Textures(lights: lights, ground: ground)
            } else {
                NSLog("DeepField: Earth maps not found, the Aurora scene draws a made-up Earth")
            }
        }
        return loaded
    }

    /// In the app bundle's Resources, or, for a `swift build` binary, the repo's Resources
    /// folder found by walking up from the executable.
    private static func directory() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Earth"),
           fm.fileExists(atPath: res.appendingPathComponent("night-lights.png").path) { return res }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Earth")
            if fm.fileExists(atPath: candidate.appendingPathComponent("night-lights.png").path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// An 8-bit grayscale image into an r8 texture with a full mip chain.
    private static func load(_ url: URL, _ device: MTLDevice, _ queue: MTLCommandQueue) -> MTLTexture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d),
              let up = device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: up, sourceOffset: 0, sourceBytesPerRow: w, sourceBytesPerImage: w * h,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: tex, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }
}
