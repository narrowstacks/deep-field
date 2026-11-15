import Metal
import QuartzCore

struct BakeParams {
    var width: Float, height: Float, camDist: Float, camElev: Float
    var tanHalfFov: Float, diskIn: Float, diskOut: Float, roll: Float
    var shellR0: Float, shellR1: Float, throat: Float, starDensity: Float
    var scene: Float, galaxies: Float, lookX: Float, lookY: Float
    var milkyWay: Float, nebulaType: Float = 0, nebulaSeed: Float = 0, pad2: Float = 0
}

struct FrameParams {
    var time: Float, levels: Float, diskIn: Float, diskOut: Float
    var exposure: Float, diskSpeed: Float, flowPeriod: Float, planetCount: Float
    var shellR0: Float, shellR1: Float, saturation: Float, scene: Float
    var dither: Float, twinkle: Float, pulsars: Float, skyBrightness: Float
    var throat: Float, starCount: Float, lightCount: Float, ringStrength: Float
    var camPos: SIMD4<Float>, camRight: SIMD4<Float>, camUp: SIMD4<Float>, camFwd: SIMD4<Float>
}

struct PaletteGPU {
    var receding, approaching, core, ring, nebulaA, nebulaB, farA, farB, starWarm, starCool, galaxy, pad: SIMD4<Float>

    init(_ p: PaletteConfig) {
        receding = p.receding.simd; approaching = p.approaching.simd; core = p.core.simd; ring = p.ring.simd
        nebulaA = p.nebulaA.simd; nebulaB = p.nebulaB.simd; farA = p.farA.simd; farB = p.farB.simd
        starWarm = p.starWarm.simd; starCool = p.starCool.simd; galaxy = p.galaxy.simd; pad = .zero
    }
}

/// Static per-pixel lookups from a bake (see the texture slot list in Shaders.swift).
struct Baked {
    let textures: [MTLTexture]
    let key: WallpaperConfig.BakeKey
}

extension SIMD4 where Scalar == Float {
    init(_ v: SIMD3<Double>) { self.init(Float(v.x), Float(v.y), Float(v.z), 0) }
}

final class Renderer {
    static let shared = Renderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let bakePipelines: [SceneKind: MTLComputePipelineState]
    private let skyPipeline: MTLComputePipelineState
    private let framePipelines: [SceneKind: MTLRenderPipelineState]
    let start = CACurrentMediaTime()

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available")
        }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
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

    /// Trace every pixel's light ray once. Reruns only when the size or a bake-affecting setting changes.
    func bake(width w: Int, height h: Int, config c: WallpaperConfig, wait: Bool) -> Baked? {
        let formats: [MTLPixelFormat] = [.rgba32Float, .rgba32Float, .rgba32Float,
                                         .rgba32Float, .rgba16Float, .rgba32Float, .rgba16Float,
                                         .rgba32Float]
        let textures = formats.compactMap { makeTexture($0, w, h) }
        guard textures.count == formats.count, let pipeline = bakePipelines[c.scene],
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        let cam = Camera(c, aspect: Double(w) / Double(h))
        let look = Camera.look(for: c.scene)
        var p = BakeParams(width: Float(w), height: Float(h),
                           camDist: Float(Camera.distance(for: c.scene)), camElev: Float(c.cameraTilt / 180 * .pi),
                           tanHalfFov: Float(cam.tanHalf), diskIn: Scene.diskIn,
                           diskOut: Float(c.scene == .tidalDisruption ? 40 : c.diskSize),
                           roll: Float(Scene.roll),
                           shellR0: Scene.shellRadii[0], shellR1: Scene.shellRadii[1],
                           throat: Float(c.throat), starDensity: Float(c.starDensity),
                           scene: c.scene.shaderIndex, galaxies: c.galaxies ? 1 : 0,
                           lookX: Float(look.x), lookY: Float(look.y), milkyWay: c.milkyWay ? 1 : 0,
                           nebulaType: c.nebulaType.shaderIndex, nebulaSeed: Float(c.nebulaSeed))
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
        skyEnc.setTexture(textures[7], index: 0)
        skyEnc.setTexture(textures[2], index: 1)
        skyEnc.setBytes(&p, length: MemoryLayout<BakeParams>.stride, index: 0)
        skyEnc.dispatchThreads(grid, threadsPerThreadgroup: group)
        skyEnc.endEncoding()
        cb.commit()
        if wait { cb.waitUntilCompleted() }
        return Baked(textures: textures, key: c.bakeKey)
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
        let planetCount = planets.count, starCount = stars.count, lightCount = lights.count
        // setFragmentBytes needs at least one element
        if planets.isEmpty { planets = [PlanetGPU(center: .zero, colorA: .zero, colorB: .zero, misc: .zero)] }
        if stars.isEmpty { stars = [StarGPU(pos: .zero, color: .zero, misc: .zero)] }
        if lights.isEmpty { lights = [LightGPU(pos: .zero, color: .zero)] }

        let wrap = Double(Scene.flowPeriod) * 1000   // disk animation is periodic in flowPeriod
        var f = FrameParams(time: Float(elapsed.truncatingRemainder(dividingBy: wrap)), levels: Float(c.levels),
                            diskIn: Scene.diskIn, diskOut: Float(c.diskSize),
                            exposure: Float(c.brightness), diskSpeed: Float(1.6 * c.diskSpeed),
                            flowPeriod: Scene.flowPeriod, planetCount: Float(planetCount),
                            shellR0: Scene.shellRadii[0], shellR1: Scene.shellRadii[1],
                            saturation: Float(c.saturation), scene: c.scene.shaderIndex,
                            dither: c.dither.shaderIndex, twinkle: Float(c.twinkles.rate),
                            pulsars: c.pulsars ? 1 : 0, skyBrightness: Float(c.nebula),
                            throat: Float(c.throat), starCount: Float(starCount), lightCount: Float(lightCount),
                            ringStrength: Float(c.photonRing),
                            camPos: SIMD4(cam.pos),
                            camRight: SIMD4(Float(cam.right.x), Float(cam.right.y), Float(cam.right.z), Float(target.width)),
                            camUp: SIMD4(Float(cam.up.x), Float(cam.up.y), Float(cam.up.z), Float(target.height)),
                            camFwd: SIMD4(cam.fwd))
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
