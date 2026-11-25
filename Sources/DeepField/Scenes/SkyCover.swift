import Foundation
import simd

/// Which of the sky a scene's own bodies leave open at one moment, for placing sky events where
/// they can be seen. It reads the same `SceneParams` the shader draws the bodies from, so it follows
/// their settings and motion. Scenes not in `scenes` leave nearly all the sky open.
struct SkyCover {
    static let scenes: Set<SceneKind> = [.auroraOrbit, .gasGiant, .roguePlanet, .ringedPlanet, .eclipse, .stellarSurface]
    private let scene: SceneKind, cam: Camera, p: SceneParamsGPU
    /// Kept clear of a body's edge (its limb glow, and the few pixels a supernova spans), in half
    /// screen heights and in radians.
    private let edge = 0.04, margin: Double

    init?(_ c: WallpaperConfig, camera: Camera, at t: Double) {
        guard Self.scenes.contains(c.scene) else { return nil }
        scene = c.scene
        cam = camera
        margin = edge * camera.tanHalf
        p = SceneParams.build(c, elapsed: t, camera: camera, width: 0, height: 0,
                              events: EventSchedule(seed: 0, enabled: false), demo: [:])
    }

    /// Whether the sky shows along world direction `d`.
    func open(_ d: SIMD3<Double>) -> Bool {
        func outside(_ body: SIMD4<Float>, _ d: SIMD3<Double>) -> Bool {
            guard body.w > 0 else { return true }
            let center = body.xyz, far = simd_length(center)
            return Self.angle(d, center / far) > asin(min(Double(body.w) / far, 1)) + margin
        }
        // most scenes have their own frame: the camera at the origin, looking down +z
        let l = SIMD3(simd_dot(d, cam.right), simd_dot(d, cam.up), simd_dot(d, cam.fwd))
        switch scene {
        case .gasGiant: return outside(p.a, l)     // its small moon passes in seconds
        case .roguePlanet: return outside(p.a, l) && outside(p.g, l)
        case .ringedPlanet: return outside(SIMD4(SIMD3<Float>(-cam.pos), p.a.w), d) && !behindDenseRing(d)
        case .auroraOrbit:
            // the ray clears the air, which dims the stars up to 1.03 Earth radii
            let rd = Self.pitched(l, Double(p.a.x)), ro = SIMD3(0, 1 + Double(p.a.y), 0)
            return simd_length(ro - rd * simd_dot(ro, rd)) > 1.02
        case .stellarSurface:
            guard let q = screen(d) else { return false }
            return simd_distance(q, SIMD2(Double(p.a.x), Double(p.a.y))) > Double(p.a.z) + edge * cam.screenScale
        case .eclipse: return eclipseOpen(d)
        default: return true
        }
    }

    /// The ringed planet's rings let light through, but at high density the classic style's middle
    /// ring (`b` in rgRingOpacity, opacity 0.55 to 0.85 before density) is nearly opaque.
    private func behindDenseRing(_ d: SIMD3<Double>) -> Bool {
        guard p.j.x == RingStyle.classic.shaderIndex, p.j.z > 1.3 else { return false }
        let n = p.a.xyz, den = simd_dot(d, n), t = abs(den) > 1e-4 ? -simd_dot(cam.pos, n) / den : -1
        let r = simd_length(cam.pos + d * t) / Double(p.a.w)
        let unstretched = 1.24 + (r - 1.24) / Double(p.j.y)     // the width setting, as in the shader
        return t > 0 && unstretched > 1.5 && unstretched < 1.98
    }

    private func eclipseOpen(_ d: SIMD3<Double>) -> Bool {
        guard let q = screen(d) else { return false }
        let th = Double(p.i.x), margin = edge * th * cam.screenScale
        let rd = Self.pitched(simd_normalize(SIMD3(q.x * th, q.y * th, 1)), Double(p.i.y))
        // the ground: the horizon's dip (8 degrees), under far rims up to 0.027 radians tall
        if p.e.w > 0.5, asin(rd.y) < -0.139 + 0.027 + margin { return false }
        // the sun with its bright inner corona, and the occluder over it (off the sun it's daylight)
        if Self.angle(rd, p.a.xyz) < atan(1.6 * Double(p.a.w)) + margin { return false }
        if p.f.w > 0 {
            let body = p.f.xyz, tanR = Double(p.f.w)
            if Self.angle(rd, body) < atan(tanR) + margin { return false }
            if p.l.z == EclipseSkyBody.ringedGiant.shaderIndex {
                let n = simd_normalize(SIMD3(0.6, 1.0, -0.1))     // the ring plane, as in the shader
                let den = simd_dot(rd, n), t = abs(den) > 1e-4 ? simd_dot(body, n) / den : -1
                let r = simd_distance(rd * t, body) / (tanR / (1 + tanR * tanR).squareRoot())
                if t > 0, r > 1.25, r < 2.45 { return false }
            }
        }
        // the air's extinction, worse low down, and the clouds' average cover (they drift); with
        // under a tenth of the light left an event is lost in the glow
        let density = Double(p.k.w)
        guard density > 0 else { return true }
        let y = max(rd.y, 0), airmass = 1 / (y + 0.065 * exp(-y * 10) + 0.012)
        let air = p.k.xyz, haze = Double(p.l.x)
        let beta = (0..<3).map { i in
            air[i] * (1 - 0.5 * min(haze, 1)) + 0.6 * haze * (0.3 + 0.7 * max(1.15 - air[i], 0))
        }.min()!
        return exp(-density * airmass * (0.2 + 0.3 * beta)) * (1 - 0.6 * Double(p.l.y)) > 0.1
    }

    /// How dark the sky is, 0 to 1. Only the eclipse's drowns its stars, in daylight (`starVis` there).
    var darkness: Double { scene == .eclipse ? smoothstep(2.6, 4.5, -Double(p.j.w)) : 1 }

    /// Where `d` shows on the screen, in half screen heights as the screen-space scenes count them.
    private func screen(_ d: SIMD3<Double>) -> SIMD2<Double>? {
        cam.project(d).map { SIMD2($0.x * cam.aspect, $0.y) * cam.screenScale }
    }

    private static func pitched(_ r: SIMD3<Double>, _ a: Double) -> SIMD3<Double> {
        SIMD3(r.x, r.y * cos(a) + r.z * sin(a), -r.y * sin(a) + r.z * cos(a))
    }

    private static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(max(simd_dot(a, b), -1), 1))
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Double> { SIMD3(Double(x), Double(y), Double(z)) }
}

/// The open sky over an event's life: covers spread through it, since bodies move.
struct OpenSky {
    let camera: Camera, covers: [SkyCover]

    /// nil if nothing in the scene covers the sky.
    init?(_ c: WallpaperConfig, camera: Camera, start: Double, duration: Double) {
        covers = (0...4).compactMap { SkyCover(c, camera: camera, at: start + duration * Double($0) / 4) }
        self.camera = camera
        if covers.isEmpty { return nil }
    }

    /// Open through the first half, while a supernova is bright.
    func open(_ d: SIMD3<Double>) -> Bool { covers.prefix(3).allSatisfy { $0.open(d) } }

    /// How many of 11 steps of a comet's pass from `a` to `b` are in open sky; it needs 9.
    private func openSteps(from a: SIMD3<Double>, to b: SIMD3<Double>, anywhere: Bool = true) -> Int {
        (1..<12).filter { i in
            let f = Double(i) / 12
            let d = simd_normalize(simd_mix(a, b, SIMD3(repeating: f)))
            return covers[Int((f * 4).rounded())].open(d) && (anywhere || onScreen(d))
        }.count
    }

    private func onScreen(_ d: SIMD3<Double>) -> Bool {
        camera.project(d).map { abs($0.x) < 1 && abs($0.y) < 1 } ?? false
    }

    func open(from a: SIMD3<Double>, to b: SIMD3<Double>) -> Bool { openSteps(from: a, to: b) >= 9 }

    /// Open spots on a grid over the screen, enough to find any patch worth using.
    func spots() -> [SIMD3<Double>] {
        (0..<14).flatMap { j in
            (0..<24).map { i in camera.ray(-0.96 + 1.92 * Double(i) / 23, -0.94 + 1.88 * Double(j) / 13) }
        }.filter(open)
    }

    /// The first of some random placements (a supernova's spot, or a comet's two ends) in open sky,
    /// so one that already was stays put. If a dozen miss, a spot off the grid (for a comet, with
    /// the farthest spot it can reach through open sky, or if that's too near to see it move, a
    /// short path across the patch, brightest in it and passing behind the body or off the
    /// screen); nil if there's none.
    func place(first: [SIMD3<Double>], _ rng: inout Rng, next: (inout Rng) -> [SIMD3<Double>]) -> [SIMD3<Double>]? {
        var dirs = first
        for _ in 0..<12 {
            if dirs.count == 1 ? open(dirs[0]) : open(from: dirs[0], to: dirs[1]) { return dirs }
            dirs = next(&rng)
        }
        let spots = spots()
        guard !spots.isEmpty else { return nil }
        let a = spots[min(Int(rng.next() * Double(spots.count)), spots.count - 1)]
        if first.count == 1 { return [a] }
        let reach = 0.4                           // half screen heights
        if let b = spots.sorted(by: { simd_dot($0, a) < simd_dot($1, a) }).first(where: { open(from: a, to: $0) }),
           simd_dot(a, b) < cos(reach * camera.tanHalf) { return [a, b] }
        guard let at = camera.project(a) else { return [a, a] }
        return (0..<12).map { i -> [SIMD3<Double>] in
            let q = Double(i) * .pi / 6, step = SIMD2(cos(q) / camera.aspect, sin(q)) * reach / 2
            return [camera.ray(at.x - step.x, at.y - step.y), camera.ray(at.x + step.x, at.y + step.y)]
        }.max { openSteps(from: $0[0], to: $0[1], anywhere: false) < openSteps(from: $1[0], to: $1[1], anywhere: false) }
    }
}

extension EventSchedule {
    /// Why a supernova or comet starting at `t` couldn't be seen on a screen of any of these
    /// aspects, or nil if it could.
    static func hiddenReason(_ k: Kind, config c: WallpaperConfig, aspects: [Double], at t: Double) -> String? {
        guard k.id == supernova.id || k.id == comet.id else { return nil }
        let name = k.id == comet.id ? "comet" : "supernova"
        let skies = aspects.compactMap { OpenSky(c, camera: Camera(c, aspect: $0), start: t, duration: k.duration) }
        guard let camera = skies.first?.camera else { return nil }
        if skies.allSatisfy({ $0.spots().isEmpty }) { return "No open sky for a \(name) with these settings" }
        // it should show soon after the click: a supernova in its flash, a comet early in its pass
        let ages = [3.0, 6, 10, 15, 20, 25] + (k.id == comet.id ? [30, 40, 50, 60] : [])
        let enough = k.id == comet.id ? 0.1 : 0.02     // the flash shows through more glow
        let dark = ages.contains { (SkyCover(c, camera: camera, at: t + $0)?.darkness ?? 1) > enough }
        return dark ? nil : "The sky is too bright for a \(name) now"
    }
}
