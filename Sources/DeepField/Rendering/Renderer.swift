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
    /// The camera the rays were traced from. Frames drawn from this bake use it too, so while a
    /// new tilt waits for its bake the view holds still instead of moving its camera through
    /// the old rays.
    let camera: Camera

    /// The shaded size it was traced at (the direction lookup is allocated for every scene).
    var size: (Int, Int) { (textures[Renderer.Slot.dir.rawValue].width, textures[Renderer.Slot.dir.rawValue].height) }

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
    private let library: MTLLibrary
    /// Each scene's fragment function, by scene.
    private static let fragmentNames: [SceneKind: String] = [
        .blackHole: "lensedFragment", .wormhole: "lensedFragment", .tidalDisruption: "tdeFragment",
        .binary: "systemFragment", .trinary: "systemFragment", .galaxy: "galaxyFragment",
        .pulsar: "pulsarFragment", .nebula: "nebulaFragment", .comet: "cometFragment",
        .stellarSurface: "stellarFragment", .planetaryNebula: "planetaryFragment", .ringedPlanet: "ringedFragment", .auroraOrbit: "auroraFragment", .liveEarth: "liveEarthFragment", .gasGiant: "gasGiantFragment",
        .protoplanetaryDisk: "protoDiskFragment",
        .neutronMerger: "neutronMergerFragment", .blackHoleMerger: "blackHoleMergerFragment", .dysonSwarm: "dysonFragment", .roguePlanet: "rogueFragment", .eclipse: "eclipseFragment", .quasar: "quasarFragment",
    ]
    /// Bloom: the scene passes writing linear light to a float target (built on first use), the
    /// bright pass, the blur, the composite, and the intermediate textures per target size.
    private var linearPipelines: [String: MTLRenderPipelineState] = [:]
    private let bloomBright: MTLComputePipelineState
    private let bloomBlur: MTLComputePipelineState
    private let bloomDown: MTLComputePipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let transitionPipeline: MTLRenderPipelineState
    private var bloomTargets: [SIMD2<Int>: BloomTargets] = [:]
    private let bloomLock = NSLock()
    /// Text over finished frames (`labelFragment`), one pipeline per target format, built on first use.
    private var labelPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    /// Fills the aurora's per-frame table of its curtains along the oval (`auroraLUT`).
    private let auroraLUTPipeline: MTLComputePipelineState
    /// The aurora's table, built on first use and shared by every view (guarded by `bloomLock`).
    private var auroraLUT: MTLTexture?

    private struct BloomTargets {
        let hdr: MTLTexture       // the scene's linear light, full size
        /// Ping-pong pairs for the blur: quarter size, then each level half the one before.
        let levels: [(a: MTLTexture, b: MTLTexture)]
    }
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
                try Self.renderPipeline(device, lib, fragment, format: .bgra8Unorm)
            }
            library = lib
            let flat = try compute("bakeFlat"), blackHole = try compute("bakeBlackHole")
            bakePipelines = [.blackHole: blackHole, .tidalDisruption: blackHole, .wormhole: try compute("bakeWormhole"),
                             .binary: flat, .trinary: flat, .galaxy: flat, .pulsar: flat, .comet: flat,
                             .stellarSurface: flat, .planetaryNebula: flat, .ringedPlanet: flat, .auroraOrbit: flat, .liveEarth: flat, .gasGiant: flat,
                             .protoplanetaryDisk: flat, .neutronMerger: flat, .blackHoleMerger: flat, .dysonSwarm: flat, .roguePlanet: flat, .eclipse: flat, .quasar: flat, .nebula: try compute("bakeNebula")]
            skyPipeline = try compute("skyPass")
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            placeholder = device.makeTexture(descriptor: d)!
            var byName: [String: MTLRenderPipelineState] = [:]
            for name in Set(Self.fragmentNames.values) { byName[name] = try render(name) }
            framePipelines = Self.fragmentNames.mapValues { byName[$0]! }
            bloomBright = try compute("bloomBright")
            bloomBlur = try compute("bloomBlur")
            bloomDown = try compute("bloomDown")
            auroraLUTPipeline = try compute("auroraLUT")
            imagePipeline = try render("imageFragment")
            transitionPipeline = try render("transitionFragment")
        } catch {
            fatalError("Shader compile failed: \(error)")
        }
    }

    var elapsed: Double { CACurrentMediaTime() - start }

    private static func renderPipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ fragment: String,
                                       format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = lib.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: desc)
    }

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
        let tde = c.scene == .tidalDisruption   // no planets; its stream and star use the shell slots
        return Slot.allCases.map { slot -> MTLPixelFormat? in
            switch slot {
            case .hitA, .hitB: lens == 1 ? .rgba32Float : (c.scene == .nebula ? .rgba16Float : nil)
            case .sky: .rgba16Float
            case .shell0P, .shell1P: shells ? .rgba16Unorm : (tde ? .rgba16Float : nil)
            case .shell0D, .shell1D: shells ? .rgba16Snorm : nil
            case .dir: .rg16Snorm
            case .info: lens > 0 ? (tde ? .rgba32Float : .r32Float) : nil
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
        let look = cam.look
        var p = BakeParams(width: Float(w), height: Float(h),
                           camDist: Float(cam.distance), camElev: Float(c.cameraTilt / 180 * .pi),
                           tanHalfFov: Float(cam.tanHalf), diskIn: SceneGeometry.diskIn,
                           diskOut: Float(c.scene == .tidalDisruption ? TDEGeometry.diskOuter * 1.2 : c.diskSize),
                           roll: Float(SceneGeometry.roll),
                           shellR0: SceneGeometry.shellRadii[0], shellR1: SceneGeometry.shellRadii[1],
                           throat: Float(c.throat), starDensity: Float(c.starDensity),
                           lensing: Self.lensing(c.scene), galaxies: c.galaxies ? 1 : 0,
                           lookX: Float(look.x), lookY: Float(look.y), milkyWay: c.milkyWay ? 1 : 0,
                           nebulaType: c.nebulaType.shaderIndex, nebulaSeed: Float(c.nebulaSeed),
                           shells: shells ? 1 : 0, skySeed: Float(c.skySeed % 1_000_000))
        enc.setComputePipelineState(pipeline)
        enc.setTextures(textures, range: 0..<textures.count)
        enc.setBytes(&p, length: MemoryLayout<BakeParams>.stride, index: 0)
        var tde = c.scene == .tidalDisruption ? SceneParams.tidalDisruptionBake(c) : SceneParamsGPU()
        enc.setBytes(&tde, length: MemoryLayout<SceneParamsGPU>.stride, index: 1)
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
        return Baked(textures: textures, key: c.bakeKey, shells: shells, bytes: bytes, camera: cam)
    }

    /// `elapsed` is seconds since launch (Double, so long orbital periods stay precise).
    /// `orbitTime`, if given, holds planets and star orbits at that time instead (phone loops).
    /// With bloom on, the scene renders its linear light to a float texture, and the bloom passes
    /// and the final tone map and dither (`imageFragment`) follow; with it off (the default) the
    /// scene pass finishes the image itself and nothing else runs.
    /// `demo` holds the events started by hand (Show Me, `--demo`): event kind id to start time.
    func encodeFrame(_ cb: MTLCommandBuffer, target: MTLTexture, baked: Baked, elapsed: Double,
                     config c: WallpaperConfig, events: EventSchedule, orbitTime: Double? = nil,
                     demo: [UInt64: Double] = ConfigStore.shared.demoEvents) {
        let bloomAmount = c.bloom + c.scene.extraBloom
        let bloom = bloomAmount > 0 ? bloomResources(for: c.scene, width: target.width, height: target.height) : nil

        let aspect = Double(target.width) / Double(target.height)
        let cam = baked.camera.aspect == aspect ? baked.camera : Camera(c, aspect: aspect)
        var planets = PlanetFactory.make(c).map { $0.gpu(elapsed: orbitTime ?? elapsed) }
        var stars = StarSystem.stars(c, elapsed: orbitTime ?? elapsed)
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
                            screenScale: Float(cam.screenScale),
                            twinkleBrightness: Float(c.twinkleBrightness), twinkleSpeed: Float(c.twinkleSpeed),
                            camPos: SIMD4(cam.pos),
                            camRight: SIMD4(Float(cam.right.x), Float(cam.right.y), Float(cam.right.z), Float(target.width)),
                            camUp: SIMD4(Float(cam.up.x), Float(cam.up.y), Float(cam.up.z), Float(target.height)),
                            image: SIMD4(Float(c.contrast), Float(c.blackPoint), Float(c.highlights), Float(c.vignette)),
                            bloom: SIMD4(Float(bloomAmount), Float(c.bloomThreshold), bloom == nil ? 0 : 1, Float(c.bloomRadius)))
        var palette = PaletteGPU(c.palette)
        var ev = events.gpu(at: elapsed, config: c, camera: cam, heightPixels: target.height, demo: demo)

        var galaxy = c.scene == .galaxy ? GalaxyModel.gpu(c, elapsed: elapsed) : .empty
        var sceneParams = SceneParams.build(c, elapsed: elapsed, camera: cam, width: target.width,
                                            height: target.height, events: events, demo: demo)
        // the aurora's table pass goes first, since a command buffer has one open encoder at a time
        let lut = c.scene == .auroraOrbit ? encodeAuroraLUT(cb, frame: &f, scene: &sceneParams) : nil
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = bloom?.targets.hdr ?? target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(bloom?.scene ?? framePipelines[c.scene]!)
        enc.setFragmentTextures(baked.textures, range: 0..<baked.textures.count)
        if c.scene == .auroraOrbit {
            // the real Earth at night, if its maps are there (S.g.z tells the shader)
            let earth = EarthMaps.textures(device, queue)
            sceneParams.g.z = earth == nil ? 0 : 1
            enc.setFragmentTexture(earth?.lights ?? placeholder, index: 10)
            enc.setFragmentTexture(earth?.ground ?? placeholder, index: 11)
            enc.setFragmentTexture(lut ?? placeholder, index: 12)
        }
        var labels: [SIMD4<Float>] = []
        if c.scene == .liveEarth {
            bindLiveEarth(enc, c, elapsed: elapsed, &sceneParams)
            var planets = SceneParams.liveEarthPlanets(c, elapsed: elapsed, sceneParams)
            labels = SceneParams.liveEarthLabels(c, planets, sceneParams, camera: cam,
                                                 width: target.width, height: target.height)
            sceneParams.o.x = Float(planets.count)
            if planets.isEmpty { planets = [SkyPlanetGPU(dir: .zero, color: .zero, light: .zero, pole: .zero)] }
            enc.setFragmentBytes(&planets, length: MemoryLayout<SkyPlanetGPU>.stride * planets.count, index: 8)
        }
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
        if let bloom { encodeBloom(cb, bloom.targets, target: target, frame: &f) }
        if !labels.isEmpty { encodeLabels(cb, target: target, labels: labels) }
    }

    /// Draws labels over the finished frame in `target`: solid letters and a soft shadow blended
    /// over it, after the tone map and dither, so the text stays clean. Each label is (left edge,
    /// vertical center, name, font pixel size), in target pixels.
    func encodeLabels(_ cb: MTLCommandBuffer, target: MTLTexture, labels: [SIMD4<Float>]) {
        bloomLock.lock()
        if labelPipelines[target.pixelFormat] == nil {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            desc.fragmentFunction = library.makeFunction(name: "labelFragment")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = target.pixelFormat
            att.isBlendingEnabled = true
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .zero
            att.destinationAlphaBlendFactor = .one
            labelPipelines[target.pixelFormat] = try? device.makeRenderPipelineState(descriptor: desc)
        }
        let pipeline = labelPipelines[target.pixelFormat]
        bloomLock.unlock()
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let pipeline, let pass = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var list = labels
        var info = SIMD4<Float>(Float(labels.count), 0.82, 0.55, 0)
        pass.setRenderPipelineState(pipeline)
        pass.setFragmentBytes(&list, length: MemoryLayout<SIMD4<Float>>.stride * list.count, index: 0)
        pass.setFragmentBytes(&info, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        pass.endEncoding()
    }

    /// Mixes two finished frames into `target` with a transition (`transitionFragment`):
    /// `progress` 0 shows `from`, 1 shows `to`. `seed` varies the pattern or direction, and the
    /// two configs give the levels and dither the mix is dithered back onto.
    func encodeTransition(_ cb: MTLCommandBuffer, target: MTLTexture, from: MTLTexture, to: MTLTexture,
                          progress: Double, seed: Float, style: TransitionStyle,
                          fromConfig: WallpaperConfig, toConfig: WallpaperConfig) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let pass = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var params = [SIMD4<Float>(Float(min(max(progress, 0), 1)), seed, style.shaderIndex, 0),
                      SIMD4<Float>(Float(fromConfig.levels), fromConfig.dither.shaderIndex,
                                   Float(toConfig.levels), toConfig.dither.shaderIndex)]
        pass.setRenderPipelineState(transitionPipeline)
        pass.setFragmentTexture(from, index: 0)
        pass.setFragmentTexture(to, index: 1)
        pass.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        pass.endEncoding()
    }

    /// Live Earth's maps (slots 10 to 22, see ShaderSource) and the live layers that are on; the
    /// flags in S.h tell the shader which ones it got.
    private func bindLiveEarth(_ enc: MTLRenderCommandEncoder, _ c: WallpaperConfig, elapsed: Double, _ s: inout SceneParamsGPU) {
        let night = EarthMaps.textures(device, queue)
        let day = EarthMaps.dayTextures(device, queue)
        let feeds = LiveEarthFeeds.shared
        let clouds = c.earthClouds ? feeds.texture(.clouds, device, queue) : nil
        let aurora = c.earthAurora ? feeds.texture(.aurora, device, queue) : nil
        s.h.x = clouds == nil ? 0 : 1
        s.h.y = aurora == nil ? 0 : 1
        s.h.z = night == nil || day == nil ? 0 : 1
        let sky = EarthMaps.skyTextures(device, queue)
        s.j.z = sky == nil ? 0 : 1
        let textures: [MTLTexture?] = [night?.lights, night?.ground, day?.january, day?.july, day?.water, day?.moon, clouds, aurora,
                                       sky?.stars, sky?.milkyWay]
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t ?? placeholder, index: 10 + i) }
        // A frozen moment in the past (and a time-lapse running from one) shows that day's real
        // clouds, moving between frames; anything else keeps the live map.
        var moment: HistoricalClouds.Moment?
        if c.earthClouds && c.earthFreezeTime {
            let date = SceneParams.liveEarthDate(c, elapsed: elapsed)
            let home = Astronomy.point(latitude: c.homeLatitude, longitude: c.homeLongitude)
            if let source = HistoricalClouds.source(for: date, home: home, distance: c.earthDistance) {
                moment = HistoricalClouds.shared.moment(date, source: source, device: device, queue: queue)
            }
        }
        s.p = SIMD4(moment == nil ? 0 : 1, moment?.fraction ?? 0, 0, 0)
        enc.setFragmentTexture(moment?.a ?? placeholder, index: 20)
        enc.setFragmentTexture(moment?.b ?? placeholder, index: 21)
        enc.setFragmentTexture(moment?.flow ?? placeholder, index: 22)
    }

    /// Fills the aurora's per-frame table: everything about the curtains that depends only on the
    /// angle round the pole and on time. One texture serves every view, since all frames go
    /// through the one command queue, which runs each buffer's passes in order.
    private func encodeAuroraLUT(_ cb: MTLCommandBuffer, frame f: inout FrameParams,
                                 scene s: inout SceneParamsGPU) -> MTLTexture? {
        bloomLock.lock()
        if auroraLUT == nil {
            // 8192 texels round the pole: about six per cell of the finest ray noise
            auroraLUT = makeTexture(device.supports32BitFloatFiltering ? .rgba32Float : .rgba16Float, 8192, 2)
        }
        let lut = auroraLUT
        bloomLock.unlock()
        guard let lut, let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(auroraLUTPipeline)
        enc.setTexture(lut, index: 0)
        enc.setBytes(&f, length: MemoryLayout<FrameParams>.stride, index: 0)
        enc.setBytes(&s, length: MemoryLayout<SceneParamsGPU>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: lut.width, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        return lut
    }

    /// The scene's linear-light pipeline and the intermediate textures for a target size.
    private func bloomResources(for scene: SceneKind, width w: Int, height h: Int)
        -> (scene: MTLRenderPipelineState, targets: BloomTargets)? {
        bloomLock.lock()
        defer { bloomLock.unlock() }
        let name = Self.fragmentNames[scene]!
        if linearPipelines[name] == nil {
            linearPipelines[name] = try? Self.renderPipeline(device, library, name, format: .rgba16Float)
        }
        let size = SIMD2(w, h)
        if bloomTargets[size] == nil {
            guard let hdr = makeTexture(.rgba16Float, w, h, usage: [.renderTarget, .shaderRead]) else { return nil }
            // enough levels for the widest radius on a 6K display (sigma ~100 quarter texels)
            var levels: [(a: MTLTexture, b: MTLTexture)] = []
            var lw = max(1, (w + 3) / 4), lh = max(1, (h + 3) / 4)
            while levels.count < 7 {
                guard let a = makeTexture(.rgba16Float, lw, lh), let b = makeTexture(.rgba16Float, lw, lh) else { return nil }
                levels.append((a, b))
                if min(lw, lh) < 8 { break }
                lw = (lw + 1) / 2; lh = (lh + 1) / 2
            }
            if bloomTargets.count >= 6 { bloomTargets.removeAll() }   // sizes come and go (previews, exports)
            bloomTargets[size] = BloomTargets(hdr: hdr, levels: levels)
        }
        guard let pipeline = linearPipelines[name], let targets = bloomTargets[size] else { return nil }
        return (pipeline, targets)
    }

    /// Bright pass into a quarter-size texture, halved until the glow's sigma is 3 texels or less,
    /// a horizontal and a vertical blur there, then the composite that adds the glow and tone
    /// maps, quantizes and dithers into `target`.
    private func encodeBloom(_ cb: MTLCommandBuffer, _ t: BloomTargets, target: MTLTexture, frame f: inout FrameParams) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        func dispatch(_ out: MTLTexture) {
            enc.dispatchThreads(MTLSize(width: out.width, height: out.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        enc.setComputePipelineState(bloomBright)
        enc.setTexture(t.hdr, index: 0)
        enc.setTexture(t.levels[0].a, index: 1)
        enc.setBytes(&f, length: MemoryLayout<FrameParams>.stride, index: 0)
        dispatch(t.levels[0].a)
        // the radius is a fraction of the frame's shorter side, so the glow looks the same at any size
        var sigma = f.bloom.w * Float(min(t.levels[0].a.width, t.levels[0].a.height))
        var k = 0
        enc.setComputePipelineState(bloomDown)
        while sigma > 3, k + 1 < t.levels.count {
            enc.setTexture(t.levels[k].a, index: 0)
            enc.setTexture(t.levels[k + 1].a, index: 1)
            dispatch(t.levels[k + 1].a)
            k += 1
            sigma /= 2
        }
        // the 4x4 means already spread the light by about 0.4 texel squared at this level
        if k > 0 { sigma = max(sigma * sigma - 0.4, 0.25).squareRoot() }
        let (a, b) = t.levels[k]
        enc.setComputePipelineState(bloomBlur)
        for (src, dst, dir) in [(a, b, SIMD2<Float>(1, 0)), (b, a, SIMD2<Float>(0, 1))] {
            var params = SIMD4<Float>(dir.x, dir.y, sigma, 0)
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch(dst)
        }
        enc.endEncoding()

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let pass = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        f.bloom.z = 0
        f.bloom.w = 1 / Float(4 << k)   // frame pixels to glow texels, for imageFragment
        pass.setRenderPipelineState(imagePipeline)
        pass.setFragmentTexture(t.hdr, index: 0)
        pass.setFragmentTexture(a, index: 1)
        pass.setFragmentBytes(&f, length: MemoryLayout<FrameParams>.stride, index: 0)
        pass.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        pass.endEncoding()
    }
}
