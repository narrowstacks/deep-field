import Foundation
import simd

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
        case .galaxy, .tidalDisruption, .pulsar, .nebula, .planetaryNebula, .ringedPlanet, .auroraOrbit, .gasGiant, .protoplanetaryDisk, .neutronMerger, .dysonSwarm, .comet, .stellarSurface:
            return []
        case .binary, .trinary:
            return stars.map { LightGPU(pos: SIMD4($0.pos.x, $0.pos.y, $0.pos.z, 0.9), color: SIMD4($0.color.x, $0.color.y, $0.color.z, 1)) }
        }
    }
}
