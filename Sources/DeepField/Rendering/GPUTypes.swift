import simd

// Uniform layouts shared with the shaders. Each struct mirrors the one of the same role in
// Shaders/ShaderCommon.swift field for field; change both together.

struct BakeParams {
    var width: Float, height: Float, camDist: Float, camElev: Float
    var tanHalfFov: Float, diskIn: Float, diskOut: Float, roll: Float
    var shellR0: Float, shellR1: Float, throat: Float, starDensity: Float
    var lensing: Float, galaxies: Float, lookX: Float, lookY: Float   // lensing: 0 none, 1 black hole, 2 wormhole
    var milkyWay: Float, nebulaType: Float, nebulaSeed: Float, shells: Float
}

struct FrameParams {
    var time: Float, levels: Float, diskIn: Float, diskOut: Float
    var exposure: Float, diskSpeed: Float, flowPeriod: Float, planetCount: Float
    var shellR0: Float, shellR1: Float, saturation: Float, scene: Float
    var dither: Float, twinkle: Float, pulsars: Float, skyBrightness: Float
    var pixelAngle: Float, starCount: Float, lightCount: Float, ringStrength: Float
    var nebulaType: Float
    var screenScale: Float     // screen-space scenes' units per half screen height (1 on the desktop)
    var camPos: SIMD4<Float>
    var camRight: SIMD4<Float>   // w = drawable width
    var camUp: SIMD4<Float>      // w = drawable height
    var image: SIMD4<Float>      // contrast, black point, highlight rolloff, vignette
    var bloom: SIMD4<Float>      // amount, threshold, linear output (1 = scene pass for bloom), radius
}

struct PaletteGPU {
    var receding, approaching, core, ring, nebulaA, nebulaB, farA, farB, starWarm, starCool, galaxy: SIMD4<Float>

    init(_ p: PaletteConfig) {
        typealias L = PickedColor.Level
        receding = p.receding.light(L.diskReceding); approaching = p.approaching.light(L.diskApproaching)
        core = p.core.light(L.diskCore); ring = p.ring.light(L.ring)
        nebulaA = p.nebulaA.simd; nebulaB = p.nebulaB.simd; farA = p.farA.simd; farB = p.farB.simd
        starWarm = p.starWarm.simd; starCool = p.starCool.simd; galaxy = p.galaxy.simd
    }
}

struct PlanetGPU {
    var center: SIMD4<Float>   // xyz, w = shell index
    var colorA: SIMD4<Float>   // rgb, w = radius
    var colorB: SIMD4<Float>   // rgb, w = noise seed
    var misc: SIMD4<Float>     // spin angle, band frequency, atmosphere

    static let empty = PlanetGPU(center: .zero, colorA: .zero, colorB: .zero, misc: .zero)
}

struct StarGPU {
    var pos: SIMD4<Float>      // xyz, w = radius
    var color: SIMD4<Float>    // rgb, w = glow scale
    var misc: SIMD4<Float>     // spin angle, seed, spot activity

    static let empty = StarGPU(pos: .zero, color: .zero, misc: .zero)
}

struct LightGPU {
    var pos: SIMD4<Float>      // xyz, w = intensity
    var color: SIMD4<Float>

    static let empty = LightGPU(pos: .zero, color: .zero)
}

/// Occasional phenomena, scheduled on the CPU (see EventSchedule).
struct EventsGPU {
    var snDir = SIMD4<Float>(0, 0, 1, 0)          // supernova sky direction, w = core brightness
    var snParams = SIMD4<Float>(repeating: 0)     // halo, echo radius (rad), echo brightness, cooling
    var cometHead = SIMD4<Float>(0, 0, 1, 0)      // sky direction, w = brightness
    var cometTail = SIMD4<Float>(0, 0, 1, 0.001)  // tail-end direction, w = head width (rad)
    // wormhole
    var farSn = SIMD4<Float>(0, 0, 1, 0)          // far-universe direction, w = core brightness
    var farSnParams = SIMD4<Float>(repeating: 0)  // halo, cooling
    var flare = SIMD4<Float>(repeating: 0)        // rim angle, brightness, angular spread
    var obj = SIMD4<Float>(repeating: 0)          // pixel x, y, brightness, size (px)
    var objDir = SIMD4<Float>(1, 0, 1, 0)         // screen velocity direction, tangential stretch
    var throat = SIMD4<Float>(repeating: 0)       // pixel x, y, radius (px)
}

struct GalaxyGPU {
    var shape: SIMD4<Float>     // type, arm count, tan(pitch), bar length (fraction of radius)
    var motion: SIMD4<Float>    // pattern angle, velocity scale, dark matter (0/1), flow period (s)
    var core: SIMD4<Float>
    var arms: SIMD4<Float>
    var nebula: SIMD4<Float>
    var dust: SIMD4<Float>
    var misc: SIMD4<Float>      // radius (scene units), solid-body angle (irregulars)

    static let empty = GalaxyGPU(shape: .zero, motion: .zero, core: .zero, arms: .zero,
                                 nebula: .zero, dust: .zero, misc: .zero)
}

/// Per-scene uniforms for the scenes built in SceneParams; each fragment shader reads these
/// slots its own way (documented above each shader).
struct SceneParamsGPU {
    var a = SIMD4<Float>(repeating: 0), b = SIMD4<Float>(repeating: 0)
    var c = SIMD4<Float>(repeating: 0), d = SIMD4<Float>(repeating: 0)
    var e = SIMD4<Float>(repeating: 0), f = SIMD4<Float>(repeating: 0)
    var g = SIMD4<Float>(repeating: 0)
}
