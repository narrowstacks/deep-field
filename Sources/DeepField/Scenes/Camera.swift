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

/// Portrait framing for phone wallpapers: each scene is recomposed for a tall frame, with the
/// subject below the lock screen clock. `zoom` and `shift` adjust the scene's defaults.
struct PhoneFraming: Codable, Equatable {
    var zoom = 1.0      // > 1 moves in closer
    var shift = 0.0     // moves the subject up (+) or down (-), as a fraction of the screen height

    /// Per scene: the horizontal half extent of the frame (tangent units; for the screen-space
    /// scenes, their own units), where the subject's center sits (v in [-1, 1], up positive),
    /// and the horizontal aim.
    static func layout(_ scene: SceneKind) -> (halfWidth: Double, subjectY: Double, lookX: Double) {
        switch scene {
        case .blackHole: (0.36, -0.2, 0)
        case .tidalDisruption: (0.68, -0.18, -9)
        case .wormhole: (0.38, -0.2, -2)
        case .binary: (0.24, -0.2, 0)
        case .trinary: (0.3, -0.2, 0)
        case .galaxy: (0.37, -0.22, 0)
        case .pulsar: (0.3, -0.18, 0)
        case .nebula: (0.5, -0.1, 0)
        case .planetaryNebula: (0.3, -0.15, 0)
        case .ringedPlanet: (0.32, -0.15, 0)
        case .auroraOrbit: (0.35, -0.1, 0)
        case .gasGiant: (0.3, -0.1, 0)
        case .protoplanetaryDisk: (0.42, -0.1, 0)
        case .neutronMerger: (0.3, -0.12, 0)
        case .blackHoleMerger: (0.32, -0.1, 0)
        case .dysonSwarm: (0.3, -0.1, 0)
        case .roguePlanet: (0.3, -0.12, 0)
        case .eclipse: (0.62, 0.0, 0)
        case .comet: (0.8, -0.45, 0)
        case .stellarSurface: (1.3, -0.5, 0)
        case .quasar: (0.34, -0.05, 0)
        }
    }
}

/// Camera basis matching the bake kernels' `cameraRay`.
struct Camera {
    let pos: SIMD3<Double>, fwd: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>
    let aspect: Double, tanHalf: Double, roll: Double
    /// The aim point and distance the bake uses (the aim differs from the scene's in portrait).
    let look: SIMD2<Double>, distance: Double
    /// Screen-space scenes (comet, star close-up): their units per half screen height, and
    /// where their subject sits (v in [-1, 1]). 1 and 0 on the desktop.
    let screenScale: Double, subjectY: Double
    let portrait: Bool

    /// Where the camera aims, relative to the scene's center. The wormhole is framed off-center;
    /// the tidal disruption aims between the hole and its star.
    static func look(for scene: SceneKind) -> SIMD2<Double> {
        switch scene {
        case .wormhole: SIMD2(-6.5, 1.2)
        case .tidalDisruption: SIMD2(-3.5, 0)
        default: .zero
        }
    }

    /// The tidal disruption pulls back so the star beside the hole fits.
    static func distance(for scene: SceneKind) -> Double {
        scene == .tidalDisruption ? 40 : SceneGeometry.camDist
    }

    init(_ c: WallpaperConfig, aspect: Double) {
        var look = Camera.look(for: c.scene)
        let distance = Camera.distance(for: c.scene)
        let e = c.cameraTilt / 180 * .pi
        self.aspect = aspect
        if let f = c.phoneFraming {
            let l = PhoneFraming.layout(c.scene)
            let zoom = min(max(f.zoom, 0.25), 4)
            let v = min(max(l.subjectY + 2 * f.shift, -0.9), 0.9)
            let screenSpace = c.scene == .comet || c.scene == .stellarSurface || c.scene == .eclipse
            if screenSpace {
                // the sky keeps the desktop's field of view; the subject scales itself
                tanHalf = max(0.27, 0.70 / aspect)
                screenScale = l.halfWidth / aspect / zoom
            } else {
                tanHalf = l.halfWidth / aspect / zoom
                screenScale = 1
                // aim above the subject so it sits at v: raise the aim point by the height
                // that subtends that angle from the camera
                look = SIMD2(l.lookX, look.y - v * tanHalf * distance / cos(e))
            }
            subjectY = v
            portrait = true
        } else {
            // keep the scene's horizontal extent roughly constant across aspect ratios
            tanHalf = max(0.27, 0.70 / aspect)
            screenScale = 1
            subjectY = 0
            portrait = false
        }
        self.look = look
        self.distance = distance
        pos = SIMD3(0, sin(e), -cos(e)) * distance
        fwd = simd_normalize(SIMD3(look.x, look.y, 0) - pos)
        right = simd_normalize(simd_cross(SIMD3(0, 1, 0), fwd))
        up = simd_cross(fwd, right)
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
