import Foundation
import simd

/// One planet's orbit and look. `PlanetFactory` lays them out from the planet seed.
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

    /// The settings a layout depends on.
    private struct Key: Equatable {
        var scene: SceneKind, seed: Int, count: Int, size: Double, orbitMinutes: Double
        init(_ c: WallpaperConfig) {
            scene = c.scene; seed = c.planetSeed; count = c.planetCount
            size = c.planetSize; orbitMinutes = c.planetOrbitMinutes
        }
    }
    // The renderer asks every frame; the layout only changes with the settings. Main thread only.
    private static var cache: (key: Key, specs: [PlanetSpec])?

    static func make(_ c: WallpaperConfig) -> [PlanetSpec] {
        let key = Key(c)
        if let cache, cache.key == key { return cache.specs }
        let specs = layout(c)
        cache = (key, specs)
        return specs
    }

    private static func layout(_ c: WallpaperConfig) -> [PlanetSpec] {
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
                orbit = SceneGeometry.shellOrbits[shell]
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
            let radius = min(rng.range(0.14, 0.32) * c.planetSize, SceneGeometry.maxPlanetRadius)
            return PlanetSpec(shell: shell, orbit: orbit, radius: radius,
                              periodMinutes: c.planetOrbitMinutes * pow(orbit / 11.5, 1.5),
                              inclination: rng.range(-32, 32), node: rng.range(-90, 90), phase: rng.range(0, 360),
                              colorA: style.a, colorB: style.b, bands: style.bands, atmosphere: style.atmosphere,
                              seed: Float(rng.range(0, 50)), spinMinutes: rng.range(3, 8))
        }
    }
}
