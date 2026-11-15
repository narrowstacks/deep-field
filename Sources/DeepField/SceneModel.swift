import Foundation
import simd

enum Scene {
    static let diskIn: Float = 3.0          // ISCO, in Schwarzschild radii
    static let camDist = 24.0
    static let roll = -0.035
    static let flowPeriod: Float = 48.0

    /// Orbit radii of the two planet shells used by the lensed scenes.
    static let shellOrbits = [7.0, 11.5]
    /// The bake shells sit this far outside each orbit, so every ray that can touch a planet crosses them.
    static let maxPlanetRadius = 0.65
    static var shellRadii: [Float] { shellOrbits.map { Float($0 + maxPlanetRadius) } }
}

/// Camera basis matching the bake kernels' `cameraRay`.
struct Camera {
    let pos: SIMD3<Double>, fwd: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>
    let aspect: Double, tanHalf: Double, roll: Double

    /// Where the camera aims, relative to the scene's center. The wormhole is framed off-center.
    static func look(for scene: SceneKind) -> SIMD2<Double> {
        scene == .wormhole ? SIMD2(-6.5, 1.2) : .zero
    }

    /// The tidal disruption pulls back so the whole orbit fits.
    static func distance(for scene: SceneKind) -> Double {
        scene == .tidalDisruption ? 42 : Scene.camDist
    }

    init(_ c: WallpaperConfig, aspect: Double) {
        self.init(tiltDegrees: c.cameraTilt, aspect: aspect, look: Camera.look(for: c.scene),
                  distance: Camera.distance(for: c.scene))
    }

    init(tiltDegrees: Double, aspect: Double, look: SIMD2<Double> = .zero, distance: Double = Scene.camDist) {
        let e = tiltDegrees / 180 * .pi
        pos = SIMD3(0, sin(e), -cos(e)) * distance
        fwd = simd_normalize(SIMD3(look.x, look.y, 0) - pos)
        right = simd_normalize(simd_cross(SIMD3(0, 1, 0), fwd))
        up = simd_cross(fwd, right)
        self.aspect = aspect
        // keep the scene's horizontal extent roughly constant across aspect ratios
        tanHalf = max(0.27, 0.70 / aspect)
        roll = Scene.roll
    }

    /// Direction from the camera to the scene's center (the hole, throat, or barycenter).
    var center: SIMD3<Double> { simd_normalize(-pos) }

    /// Screen position in [-1, 1] (x right, y up) of a direction, or nil if it's behind the camera.
    func project(_ d: SIMD3<Double>) -> SIMD2<Double>? {
        let z = simd_dot(d, fwd)
        guard z > 1e-4 else { return nil }
        let rx = simd_dot(d, right) / z / tanHalf, ry = simd_dot(d, up) / z / tanHalf
        let x = cos(roll) * rx + sin(roll) * ry, y = -sin(roll) * rx + cos(roll) * ry
        return SIMD2(x / aspect, y)
    }

    /// Camera ray for a screen position in [-1, 1].
    func ray(_ u: Double, _ v: Double) -> SIMD3<Double> {
        let x = u * aspect, y = v
        let rx = cos(roll) * x - sin(roll) * y, ry = sin(roll) * x + cos(roll) * y
        return simd_normalize(fwd + (rx * right + ry * up) * tanHalf)
    }
}

struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

// MARK: - GPU structs (layouts mirror Shaders.swift)

struct PlanetGPU {
    var center: SIMD4<Float>   // xyz, w = shell index
    var colorA: SIMD4<Float>   // rgb, w = radius
    var colorB: SIMD4<Float>   // rgb, w = noise seed
    var misc: SIMD4<Float>     // spin angle, band frequency, atmosphere
}

struct StarGPU {
    var pos: SIMD4<Float>      // xyz, w = radius
    var color: SIMD4<Float>    // rgb, w = glow scale
    var misc: SIMD4<Float>     // spin angle, seed, spot activity
}

struct LightGPU {
    var pos: SIMD4<Float>      // xyz, w = intensity
    var color: SIMD4<Float>
}

// MARK: - Planets

struct PlanetSpec {
    var shell: Int             // lensed scenes: which bake shell; -1 = free orbit (star systems)
    var orbit: Double
    var radius: Double
    var periodMinutes: Double
    var inclination: Double    // degrees
    var node: Double           // degrees
    var phase: Double          // degrees at launch
    var colorA: SIMD3<Float>
    var colorB: SIMD3<Float>
    var bands: Float
    var atmosphere: Float
    var seed: Float
    var spinMinutes: Double

    func gpu(elapsed t: Double) -> PlanetGPU {
        let a = (phase / 180 * .pi) + 2 * .pi * t / (periodMinutes * 60)
        let inc = inclination / 180 * .pi, nd = node / 180 * .pi
        // circle in the disk plane (same direction as the disk), tilted about x, then turned about y
        let x0 = cos(a) * orbit, z0 = sin(a) * orbit
        let y1 = -z0 * sin(inc), z1 = z0 * cos(inc)
        let x2 = x0 * cos(nd) - z1 * sin(nd), z2 = x0 * sin(nd) + z1 * cos(nd)
        let spin = Float((2 * .pi * t / (spinMinutes * 60)).truncatingRemainder(dividingBy: 2 * .pi))
        return PlanetGPU(center: SIMD4(Float(x2), Float(y1), Float(z2), Float(shell)),
                         colorA: SIMD4(colorA, Float(radius)), colorB: SIMD4(colorB, seed),
                         misc: SIMD4(spin, bands, atmosphere, 0))
    }
}

enum PlanetFactory {
    private struct Style { let a: SIMD3<Float>, b: SIMD3<Float>, bands: Float, atmosphere: Float }
    private static let styles: [Style] = [
        Style(a: [0.95, 0.42, 0.14], b: [0.30, 0.08, 0.04], bands: 7, atmosphere: 0.25),   // rust giant
        Style(a: [0.80, 0.90, 1.00], b: [0.22, 0.34, 0.60], bands: 3, atmosphere: 0.8),    // ice
        Style(a: [0.20, 0.55, 1.00], b: [0.03, 0.10, 0.35], bands: 12, atmosphere: 1.0),   // ocean
        Style(a: [0.95, 0.82, 0.60], b: [0.55, 0.38, 0.22], bands: 14, atmosphere: 0.3),   // banded gas giant
        Style(a: [1.00, 0.35, 0.05], b: [0.10, 0.03, 0.02], bands: 2, atmosphere: 0.1),    // lava
        Style(a: [0.35, 0.85, 0.45], b: [0.05, 0.25, 0.20], bands: 5, atmosphere: 0.7),    // jungle
        Style(a: [0.75, 0.55, 1.00], b: [0.20, 0.10, 0.40], bands: 9, atmosphere: 0.6),    // violet
    ]

    static func make(_ c: WallpaperConfig) -> [PlanetSpec] {
        if !c.scene.hasPlanets { return [] }
        var rng = Rng(UInt64(truncatingIfNeeded: c.planetSeed) &* 0x5851_F42D_4C95_7F2D &+ 7)
        var order = Array(styles.indices)
        for i in order.indices.reversed() { order.swapAt(i, Int(rng.next() * Double(i + 1))) }
        return (0..<min(c.planetCount, 6)).map { i in
            let style = styles[order[i % styles.count]]
            let shell: Int
            let orbit: Double
            switch c.scene {
            case .blackHole, .wormhole:
                shell = i % 2 == 0 ? 1 : 0
                orbit = Scene.shellOrbits[shell]
            case .binary:
                shell = -1
                orbit = rng.range(8.5, 15)
            case .trinary:
                shell = -1
                orbit = rng.range(7, 10)
            default:
                shell = -1
                orbit = 10
            }
            let radius = min(rng.range(0.14, 0.32) * c.planetSize, Scene.maxPlanetRadius)
            return PlanetSpec(shell: shell, orbit: orbit, radius: radius,
                              periodMinutes: c.planetOrbitMinutes * pow(orbit / 11.5, 1.5),
                              inclination: rng.range(-32, 32), node: rng.range(-90, 90), phase: rng.range(0, 360),
                              colorA: style.a, colorB: style.b, bands: style.bands, atmosphere: style.atmosphere,
                              seed: Float(rng.range(0, 50)), spinMinutes: rng.range(3, 8))
        }
    }
}

// MARK: - Stars and lights

enum StarSystem {
    /// Star positions for binary/trinary scenes at time t (empty for the lensed scenes).
    static func stars(_ c: WallpaperConfig, elapsed t: Double) -> [StarGPU] {
        let inc = 8.0 / 180 * .pi
        func orbitPoint(_ r: Double, _ angle: Double) -> SIMD3<Double> {
            SIMD3(cos(angle) * r, -sin(angle) * r * sin(inc), sin(angle) * r * cos(inc))
        }
        func gpu(_ type: StarType, _ p: SIMD3<Double>, _ i: Int) -> StarGPU {
            let col = type.color
            let spin = Float((2 * .pi * t / (8 * 60) + Double(i)).truncatingRemainder(dividingBy: 2 * .pi))
            return StarGPU(pos: SIMD4(SIMD3<Float>(p), Float(type.radius)),
                           color: SIMD4(col.r, col.g, col.b, Float(type.glow)),
                           misc: SIMD4(spin, Float(i) * 13.7 + 2, Float(type.activity), 0))
        }
        let period = c.starOrbitMinutes * 60
        switch c.scene {
        case .binary:
            let a = c.binaryStars[0], b = c.binaryStars[1]
            let sep = max(c.starSeparation, (a.radius + b.radius) * 1.4)
            let ang = 2 * .pi * t / period
            let m = a.mass + b.mass
            return [gpu(a, orbitPoint(sep * b.mass / m, ang), 0),
                    gpu(b, orbitPoint(sep * a.mass / m, ang + .pi), 1)]
        case .trinary:
            let a = c.trinaryStars[0], b = c.trinaryStars[1], cc = c.trinaryStars[2]
            let inner = max(c.starSeparation * 0.6, (a.radius + b.radius) * 1.4)
            let outer = max(c.starSeparation * 2.0, inner + cc.radius * 2 + 3)
            let mAB = a.mass + b.mass, mAll = mAB + cc.mass
            // inner pair whirls quickly; the third star swings around them slowly
            let outerAng = 2 * .pi * t / (period * 6)
            let pairCenter = orbitPoint(outer * cc.mass / mAll, outerAng)
            let innerAng = 2 * .pi * t / period
            return [gpu(a, pairCenter + orbitPoint(inner * b.mass / mAB, innerAng), 0),
                    gpu(b, pairCenter + orbitPoint(inner * a.mass / mAB, innerAng + .pi), 1),
                    gpu(cc, orbitPoint(outer * mAB / mAll, outerAng + .pi), 2)]
        default:
            return []
        }
    }

    static func lights(_ c: WallpaperConfig, stars: [StarGPU]) -> [LightGPU] {
        switch c.scene {
        case .blackHole:
            let p = c.palette
            let col = SIMD3<Float>(p.receding.r, p.receding.g, p.receding.b) * 0.6
                    + SIMD3<Float>(p.core.r, p.core.g, p.core.b) * 0.4
            return [LightGPU(pos: SIMD4(0, 0, 0, 1), color: SIMD4(col, 1))]
        case .wormhole:
            let p = c.palette
            let col = SIMD3<Float>(p.farA.r, p.farA.g, p.farA.b) * 0.5 + 0.25
            return [LightGPU(pos: SIMD4(0, 0, 0, 0.7), color: SIMD4(col, 1))]
        case .galaxy, .tidalDisruption, .pulsar, .nebula, .comet, .stellarSurface:
            return []
        case .binary, .trinary:
            return stars.map { LightGPU(pos: SIMD4($0.pos.x, $0.pos.y, $0.pos.z, 0.9), color: SIMD4($0.color.x, $0.color.y, $0.color.z, 1)) }
        }
    }
}
