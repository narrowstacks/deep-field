import Metal
import QuartzCore

/// Static per-pixel lookups from a bake (see the texture slot list in Shaders/ShaderSource.swift).
struct Baked {
    /// One per `Renderer.Slot`; slots the scene doesn't use hold a shared 1x1 placeholder.
    let textures: [MTLTexture]
    let key: WallpaperConfig.BakeKey
    /// Whether planet orbit-shell crossings were recorded (lensed scenes with planets).
    let shells: Bool
    /// GPU memory held by this bake's own textures.
    let bytes: Int

    /// Whether this bake still serves `c`, or it needs a new one.
    func matches(_ c: WallpaperConfig) -> Bool { key == c.bakeKey && shells == Renderer.needsShells(c) }
}

final class Renderer {
    static let shared = Renderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let bakePipelines: [SceneKind: MTLComputePipelineState]
    private let skyPipeline: MTLComputePipelineState
    private let framePipelines: [SceneKind: MTLRenderPipelineState]
    let start = CACurrentMediaTime()
    /// Bound in place of the textures a scene doesn't use.
    private let placeholder: MTLTexture

    /// Bake texture slots, matching the shaders' [[texture(n)]] indices.
    enum Slot: Int, CaseIterable {
        case hitA, hitB, sky, shell0P, shell0D, shell1P, shell1D, dir, info, starId
    }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available")
        }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: ShaderSource.full, options: nil)
            func compute(_ name: String) throws -> MTLComputePipelineState {
                try device.makeComputePipelineState(function: lib.makeFunction(name: name)!)
            }
            func render(_ fragment: String) throws -> MTLRenderPipelineState {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = lib.makeFunction(name: "fullscreenVertex")
                desc.fragmentFunction = lib.makeFunction(name: fragment)
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: desc)
            }
            let flat = try compute("bakeFlat"), blackHole = try compute("bakeBlackHole")
            bakePipelines = [.blackHole: blackHole, .tidalDisruption: blackHole, .wormhole: try compute("bakeWormhole"),
                             .binary: flat, .trinary: flat, .galaxy: flat, .pulsar: flat, .comet: flat,
                             .stellarSurface: flat, .nebula: try compute("bakeNebula")]
            skyPipeline = try compute("skyPass")
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            placeholder = device.makeTexture(descriptor: d)!
            let lensed = try render("lensedFragment"), system = try render("systemFragment")
            framePipelines = [.blackHole: lensed, .tidalDisruption: lensed, .wormhole: lensed,
                              .binary: system, .trinary: system, .galaxy: try render("galaxyFragment"),
                              .pulsar: try render("pulsarFragment"), .nebula: try render("nebulaFragment"),
                              .comet: try render("cometFragment"), .stellarSurface: try render("stellarFragment")]
        } catch {
            fatalError("Shader compile failed: \(error)")
        }
    }

    var elapsed: Double { CACurrentMediaTime() - start }

    func makeTexture(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// How a scene bends light: 0 not at all, 1 black hole (with a shadow), 2 wormhole.
    static func lensing(_ scene: SceneKind) -> Float {
        switch scene {
        case .blackHole, .tidalDisruption: 1
        case .wormhole: 2
        default: 0
        }
    }

    /// Lensed scenes find their planets through the baked orbit-shell crossings.
    static func needsShells(_ c: WallpaperConfig) -> Bool {
        lensing(c.scene) > 0 && c.scene.hasPlanets && c.planetCount > 0
    }

    /// Pixel format of each slot for a config; nil = unused (placeholder bound).
    /// Ray hits keep float32 (radii and angles feed fine noise); directions and shell
    /// crossing angles are 16-bit fixed point (well under a pixel), the sky scalars half floats.
    static func formats(for c: WallpaperConfig) -> [MTLPixelFormat?] {
        let lens = lensing(c.scene)
        let shells = needsShells(c)
        return Slot.allCases.map { slot -> MTLPixelFormat? in
            switch slot {
            case .hitA, .hitB: lens == 1 ? .rgba32Float : (c.scene == .nebula ? .rgba16Float : nil)
            case .sky: .rgba16Float
            case .shell0P, .shell1P: shells ? .rgba16Unorm : nil
            case .shell0D, .shell1D: shells ? .rgba16Snorm : nil
            case .dir: .rg16Snorm
            case .info: lens > 0 ? .r32Float : nil
            case .starId: .r16Uint
            }
        }
    }

    /// Trace every pixel's light ray once. Reruns only when the size or a bake-affecting setting
    /// changes. Textures of `old` are reused where size and format match.
    func bake(width w: Int, height h: Int, config c: WallpaperConfig, wait: Bool, reusing old: Baked? = nil) -> Baked? {
        guard let cb = queue.makeCommandBuffer(),
              let baked = encodeBake(cb, width: w, height: h, config: c, reusing: old) else { return nil }
        cb.commit()
        if wait { cb.waitUntilCompleted() }
        return baked
    }

    /// Encodes the ray bake and the sky pass into `cb` without committing it.
    func encodeBake(_ cb: MTLCommandBuffer, width w: Int, height h: Int, config c: WallpaperConfig,
                    reusing old: Baked? = nil) -> Baked? {
        var textures: [MTLTexture] = []
        var bytes = 0
        for (i, format) in Self.formats(for: c).enumerated() {
            guard let format else { textures.append(placeholder); continue }
            if let prev = old?.textures[i], prev !== placeholder, prev.pixelFormat == format,
               prev.width == w, prev.height == h {
                textures.append(prev)
            } else {
                guard let t = makeTexture(format, w, h) else { return nil }
                textures.append(t)
            }
            bytes += textures[i].allocatedSize
        }
        guard let pipeline = bakePipelines[c.scene], let enc = cb.makeComputeCommandEncoder() else { return nil }
        let shells = Self.needsShells(c)
        let cam = Camera(c, aspect: Double(w) / Double(h))
        let look = Camera.look(for: c.scene)
        var p = BakeParams(width: Float(w), height: Float(h),
                           camDist: Float(Camera.distance(for: c.scene)), camElev: Float(c.cameraTilt / 180 * .pi),
                           tanHalfFov: Float(cam.tanHalf), diskIn: SceneGeometry.diskIn,
                           diskOut: Float(c.scene == .tidalDisruption ? 40 : c.diskSize),
                           roll: Float(SceneGeometry.roll),
                           shellR0: SceneGeometry.shellRadii[0], shellR1: SceneGeometry.shellRadii[1],
                           throat: Float(c.throat), starDensity: Float(c.starDensity),
                           lensing: Self.lensing(c.scene), galaxies: c.galaxies ? 1 : 0,
                           lookX: Float(look.x), lookY: Float(look.y), milkyWay: c.milkyWay ? 1 : 0,
                           nebulaType: c.nebulaType.shaderIndex, nebulaSeed: Float(c.nebulaSeed),
                           shells: shells ? 1 : 0)
        enc.setComputePipelineState(pipeline)
        enc.setTextures(textures, range: 0..<textures.count)
        enc.setBytes(&p, length: MemoryLayout<BakeParams>.stride, index: 0)
        let grid = MTLSize(width: w, height: h, depth: 1), group = MTLSize(width: 8, height: 8, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        // second pass (own encoder, so it sees the finished ray bake): sky lookups, filtered by
        // how much lensing squeezes the sky into each pixel
        guard let skyEnc = cb.makeComputeCommandEncoder() else { return nil }
        skyEnc.setComputePipelineState(skyPipeline)
        skyEnc.setTexture(textures[Slot.dir.rawValue], index: 0)
        skyEnc.setTexture(textures[Slot.info.rawValue], index: 1)
        skyEnc.setTexture(textures[Slot.sky.rawValue], index: 2)
        skyEnc.setTexture(textures[Slot.starId.rawValue], index: 3)
        skyEnc.setBytes(&p, length: MemoryLayout<BakeParams>.stride, index: 0)
        skyEnc.dispatchThreads(grid, threadsPerThreadgroup: group)
        skyEnc.endEncoding()
        return Baked(textures: textures, key: c.bakeKey, shells: shells, bytes: bytes)
    }

    /// `elapsed` is seconds since launch (Double, so long orbital periods stay precise).
    func encodeFrame(_ cb: MTLCommandBuffer, target: MTLTexture, baked: Baked, elapsed: Double,
                     config c: WallpaperConfig, events: EventSchedule) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }

        let cam = Camera(c, aspect: Double(target.width) / Double(target.height))
        var planets = PlanetFactory.make(c).map { $0.gpu(elapsed: elapsed) }
        var stars = StarSystem.stars(c, elapsed: elapsed)
        var lights = StarSystem.lights(c, stars: stars)
        // a lensed scene baked without shells can't show planets (until the rebake catches up)
        let planetCount = Self.lensing(c.scene) > 0 && !baked.shells ? 0 : planets.count
        let starCount = stars.count, lightCount = lights.count
        // setFragmentBytes needs at least one element
        if planets.isEmpty { planets = [.empty] }
        if stars.isEmpty { stars = [.empty] }
        if lights.isEmpty { lights = [.empty] }

        let wrap = Double(SceneGeometry.flowPeriod) * 1000   // disk animation is periodic in flowPeriod
        let pixelAngle = 2 * cam.tanHalf / Double(target.height)
        var f = FrameParams(time: Float(elapsed.truncatingRemainder(dividingBy: wrap)), levels: Float(c.levels),
                            diskIn: SceneGeometry.diskIn, diskOut: Float(c.diskSize),
                            exposure: Float(c.brightness), diskSpeed: Float(1.6 * c.diskSpeed),
                            flowPeriod: SceneGeometry.flowPeriod, planetCount: Float(planetCount),
                            shellR0: SceneGeometry.shellRadii[0], shellR1: SceneGeometry.shellRadii[1],
                            saturation: Float(c.saturation), scene: c.scene.shaderIndex,
                            dither: c.dither.shaderIndex, twinkle: Float(c.twinkles.rate),
                            pulsars: c.pulsars ? 1 : 0, skyBrightness: Float(c.nebula),
                            pixelAngle: Float(pixelAngle), starCount: Float(starCount), lightCount: Float(lightCount),
                            ringStrength: Float(c.photonRing), nebulaType: c.nebulaType.shaderIndex,
                            camPos: SIMD4(cam.pos),
                            camRight: SIMD4(Float(cam.right.x), Float(cam.right.y), Float(cam.right.z), Float(target.width)),
                            camUp: SIMD4(Float(cam.up.x), Float(cam.up.y), Float(cam.up.z), Float(target.height)))
        var palette = PaletteGPU(c.palette)
        var ev = events.gpu(at: elapsed, config: c, camera: cam, heightPixels: target.height)

        var galaxy = c.scene == .galaxy ? GalaxyModel.gpu(c, elapsed: elapsed) : .empty
        var sceneParams = SceneParams.build(c, elapsed: elapsed, camera: cam, width: target.width,
                                            height: target.height, events: events)
        enc.setRenderPipelineState(framePipelines[c.scene]!)
        enc.setFragmentTextures(baked.textures, range: 0..<baked.textures.count)
        enc.setFragmentBytes(&f, length: MemoryLayout<FrameParams>.stride, index: 0)
        enc.setFragmentBytes(&planets, length: MemoryLayout<PlanetGPU>.stride * planets.count, index: 1)
        enc.setFragmentBytes(&ev, length: MemoryLayout<EventsGPU>.stride, index: 2)
        enc.setFragmentBytes(&palette, length: MemoryLayout<PaletteGPU>.stride, index: 3)
        enc.setFragmentBytes(&stars, length: MemoryLayout<StarGPU>.stride * stars.count, index: 4)
        enc.setFragmentBytes(&lights, length: MemoryLayout<LightGPU>.stride * lights.count, index: 5)
        enc.setFragmentBytes(&galaxy, length: MemoryLayout<GalaxyGPU>.stride, index: 6)
        enc.setFragmentBytes(&sceneParams, length: MemoryLayout<SceneParamsGPU>.stride, index: 7)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
