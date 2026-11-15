import Foundation
import simd

/// Fixed scene geometry. Lengths are in Schwarzschild radii of the black hole.
enum SceneGeometry {
    static let diskIn: Float = 3.0          // ISCO
    static let camDist = 24.0
    static let roll = -0.035                // camera roll, radians
    static let flowPeriod: Float = 48.0     // seconds; the disk texture's cross-fade loop

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
        scene == .tidalDisruption ? 42 : SceneGeometry.camDist
    }

    init(_ c: WallpaperConfig, aspect: Double) {
        let look = Camera.look(for: c.scene), distance = Camera.distance(for: c.scene)
        let e = c.cameraTilt / 180 * .pi
        pos = SIMD3(0, sin(e), -cos(e)) * distance
        fwd = simd_normalize(SIMD3(look.x, look.y, 0) - pos)
        right = simd_normalize(simd_cross(SIMD3(0, 1, 0), fwd))
        up = simd_cross(fwd, right)
        self.aspect = aspect
        // keep the scene's horizontal extent roughly constant across aspect ratios
        tanHalf = max(0.27, 0.70 / aspect)
        roll = SceneGeometry.roll
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
