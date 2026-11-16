import Foundation
import ImageIO
import Metal
import simd

/// The Earth maps, made by `Design/Earth/make_earth_maps.py`: NASA's Black Marble city lights
/// and the dim ground under them (Aurora from Orbit and Live Earth), and Live Earth's daytime
/// maps. Loaded on first use and kept, since they're the same for every screen (the night maps
/// take about 45 MB of GPU memory with mipmaps).
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

    /// Live Earth's daytime surface (January and July), open water and the Moon; loaded on first
    /// use like the night maps (about 47 MB of GPU memory with mipmaps).
    struct DayTextures {
        let january: MTLTexture, july: MTLTexture, water: MTLTexture, moon: MTLTexture
    }

    private static var day: DayTextures?
    private static var triedDay = false

    static func dayTextures(_ device: MTLDevice, _ queue: MTLCommandQueue) -> DayTextures? {
        lock.lock()
        defer { lock.unlock() }
        if !triedDay {
            triedDay = true
            if let dir = directory(),
               let jan = load(dir.appendingPathComponent("day-jan.jpg"), device, queue, color: true),
               let jul = load(dir.appendingPathComponent("day-jul.jpg"), device, queue, color: true),
               let water = load(dir.appendingPathComponent("water.png"), device, queue),
               let moon = load(dir.appendingPathComponent("moon.png"), device, queue) {
                day = DayTextures(january: jan, july: jul, water: water, moon: moon)
            } else {
                NSLog("DeepField: daytime Earth maps not found, Live Earth draws a made-up Earth")
            }
        }
        return day
    }

    /// The real sky for Live Earth: the bright star catalog splatted into an equirectangular map
    /// (column 0 at right ascension 0, increasing east; row 0 at declination +90), and the Milky
    /// Way's glow on the same grid.
    struct SkyTextures {
        let stars: MTLTexture, milkyWay: MTLTexture
    }

    private static var sky: SkyTextures?
    private static var triedSky = false
    static let starMapWidth = 4096

    static func skyTextures(_ device: MTLDevice, _ queue: MTLCommandQueue) -> SkyTextures? {
        lock.lock()
        defer { lock.unlock() }
        if !triedSky {
            triedSky = true
            if let dir = directory(),
               let stars = starMap(dir.appendingPathComponent("stars.bin"), device, queue),
               let milky = load(dir.appendingPathComponent("milkyway.jpg"), device, queue, color: true) {
                sky = SkyTextures(stars: stars, milkyWay: milky)
            } else {
                NSLog("DeepField: star catalog not found, Live Earth shows the usual starfield")
            }
        }
        return sky
    }

    /// Each catalog star into the texel holding its position (the brighter one where two share a
    /// texel): rgb its color from the B-V index, a its magnitude as (7 - V) / 9. The shader spreads
    /// each star over the pixels round it, so stars glide smoothly as the sky turns.
    private static func starMap(_ url: URL, _ device: MTLDevice, _ queue: MTLCommandQueue) -> MTLTexture? {
        guard let data = try? Data(contentsOf: url), data.count >= 16 else { return nil }
        let w = starMapWidth, h = w / 2
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float32.self)
            for i in 0..<(f.count / 4) {
                let ra = Double(f[4 * i]), dec = Double(f[4 * i + 1]), v = Double(f[4 * i + 2]), bv = Double(f[4 * i + 3])
                let x = min(Int(ra / (2 * .pi) * Double(w)), w - 1)
                let y = min(max(Int((0.5 - dec / .pi) * Double(h)), 0), h - 1)
                let a = UInt8(min(max((7 - v) / 9, 0), 1) * 255)
                let o = (y * w + x) * 4
                guard a > pixels[o + 3] else { continue }
                let c = starColor(bv)
                pixels[o] = UInt8(c.x * 255); pixels[o + 1] = UInt8(c.y * 255); pixels[o + 2] = UInt8(c.z * 255)
                pixels[o + 3] = a
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d),
              let up = device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: up, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: tex, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }

    /// A star's color from its B-V index: the temperature by Ballesteros' formula, then a
    /// blackbody's color, normalized so the brightest channel is 1 and pushed a little toward
    /// saturation so the colors read at a pixel's size.
    private static func starColor(_ bv: Double) -> SIMD3<Double> {
        let b = min(max(bv, -0.4), 2.0)
        let t = 4600 * (1 / (0.92 * b + 1.7) + 1 / (0.92 * b + 0.62))
        // Planck's law at 610, 550 and 465 nm, relative
        func planck(_ nm: Double) -> Double { 1 / (pow(nm * 1e-9, 5) * (exp(1.4388e-2 / (nm * 1e-9 * t)) - 1)) }
        var c = SIMD3(planck(610), planck(550), planck(465))
        c /= c.max()
        let mean = (c.x + c.y + c.z) / 3
        c = simd_clamp(mean + (c - mean) * 1.6, SIMD3(repeating: 0.05), SIMD3(repeating: 1))
        return c / c.max()
    }

    /// A file in the Earth maps folder (bundled fallbacks for Live Earth's live layers).
    static func bundled(_ name: String) -> URL? { directory()?.appendingPathComponent(name) }

    /// An 8-bit image into a texture with a full mip chain: grayscale into r8, or color into
    /// sRGB rgba8 (so sampling returns linear light).
    static func load(_ url: URL, _ device: MTLDevice, _ queue: MTLCommandQueue, color: Bool = false) -> MTLTexture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height, bpp = color ? 4 : 1
        var pixels = [UInt8](repeating: 0, count: w * h * bpp)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            let space = color ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray()
            let info = color ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * bpp,
                                      space: space, bitmapInfo: info)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: color ? .rgba8Unorm_srgb : .r8Unorm,
                                                         width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d),
              let up = device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: up, sourceOffset: 0, sourceBytesPerRow: w * bpp, sourceBytesPerImage: w * h * bpp,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: tex, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }
}
