import Foundation
import simd

// Star meets black hole: a star parked beside the hole, overflowing toward it. A stream of gas
// peels off its tidally stretched tip, spirals in along the disk plane and feeds an accretion
// disk that is already there, with optional jets along the spin axis. Everything is traced in
// the black-hole bake (see bakeBlackHole's tidal disruption part), so the star, the stream and
// the jets are lensed like the disk; the frame shader only animates and colors them.

/// Disk colors for the tidal disruption scene.
enum TDEDiskColors: String, Codable, CaseIterable, Identifiable {
    case palette, fiery, blueWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .palette: "Custom"
        case .fiery: "Fiery"
        case .blueWhite: "Blue-white"
        }
    }
}

/// The star and stream geometry, fixed for a given config (it feeds the bake).
struct TDEGeometry {
    /// Star center (in the disk plane) and its radius across the stretch.
    let center: SIMD3<Double>, radius: Double
    /// Semi-axes along the line to the hole: the stretched near half, the far half.
    let nearAxis: Double, farAxis: Double
    /// Stream: angle where it leaves the star, start and merge radii, how far round it winds
    /// (radians) by the merge, and where it ends past the merge (in units of that winding).
    let startAngle: Double, startRadius: Double, mergeRadius: Double, winding: Double, end: Double
    /// Stream half-width at the star and at the merge.
    let width0: Double, width1: Double
    static let diskOuter = 13.0

    init(_ c: WallpaperConfig) {
        let distance = min(max(c.tdeStarDistance, 15), 35)
        let r = 1.9 * c.tdeStar.radius.squareRoot() * min(max(c.tdeStarSize, 0.3), 2.5)
        // left of the hole and toward the camera, swung further round when far out so the star
        // stays in frame: x / (camera distance - z) is held at about the same value
        let camDist = Camera.distance(for: .tidalDisruption)
        var lo = Double.pi + 0.6, hi = 1.5 * Double.pi
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if distance * cos(mid) / (camDist + distance * sin(mid)) < -0.55 { lo = mid } else { hi = mid }
        }
        let angle = (lo + hi) / 2
        center = SIMD3(cos(angle), 0, sin(angle)) * distance
        radius = r
        // the more the star fills its Roche lobe, the longer its tip
        nearAxis = r * 1.45
        farAxis = r * 1.06
        startAngle = angle
        startRadius = distance - nearAxis * 0.6
        mergeRadius = Self.diskOuter * 0.86
        winding = 2.5
        end = 1.85
        width0 = r * 0.6
        width1 = 0.45
    }

    /// Bake parameters: a = (center, radius), b = (near axis, far axis, start angle, end),
    /// c = (start radius, merge radius, winding, 0), d = (width at star, width at merge, 0, 0).
    var bake: SceneParamsGPU {
        var p = SceneParamsGPU()
        p.a = SIMD4(Float(center.x), Float(center.y), Float(center.z), Float(radius))
        p.b = SIMD4(Float(nearAxis), Float(farAxis), Float(startAngle), Float(end))
        p.c = SIMD4(Float(startRadius), Float(mergeRadius), Float(winding), 0)
        p.d = SIMD4(Float(width0), Float(width1), 0, 0)
        return p
    }
}

extension SceneParams {
    static func tidalDisruptionBake(_ c: WallpaperConfig) -> SceneParamsGPU { TDEGeometry(c).bake }

    /// a = (star color, spot activity), b = (stream brightness, jets, star seed, 0),
    /// c = (jet color, disk outer radius), d/e/f = disk receding / approaching / core colors.
    static func tidalDisruption(_ c: WallpaperConfig) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let star = c.tdeStar.color
        p.a = SIMD4(star.r, star.g, star.b, Float(c.tdeStar.activity))
        p.b = SIMD4(Float(c.tdeStreamBrightness), c.tdeJets ? 1 : 0, 0, 0)
        p.c = SIMD4(c.tdeJetColor.r, c.tdeJetColor.g, c.tdeJetColor.b, Float(TDEGeometry.diskOuter))
        let (rec, app, core): (RGB, RGB, RGB) = switch c.tdeDiskColors {
        case .palette: (c.palette.receding, c.palette.approaching, c.palette.core)
        case .fiery: (RGB(1.0, 0.22, 0.03), RGB(1.0, 0.55, 0.12), RGB(1.0, 0.85, 0.5))
        case .blueWhite: (RGB(0.35, 0.5, 1.0), RGB(0.7, 0.85, 1.0), RGB(0.95, 0.97, 1.0))
        }
        p.d = rec.simd
        p.e = app.simd
        p.f = core.simd
        return p
    }
}
