import simd

/// Part of `--check-customization`: sky events keep to the open sky, and Show Me's answer matches
/// whether they're drawn.
enum SkyCoverCheck {
    static func failures() -> [String] {
        // `crossing`: too small a patch to stay in, so a comet must cross it rather than stand still
        func fails(_ scene: SceneKind, _ aspect: Double, hidden: Bool = false, crossing: Bool = false,
                   _ edit: (inout WallpaperConfig) -> Void = { _ in }) -> [String] {
            var c = WallpaperConfig(), out: [String] = []
            c.scene = scene
            edit(&c)
            let cam = Camera(c, aspect: aspect), start = 200.0
            for k in [EventSchedule.supernova, EventSchedule.comet] {
                let what = "\(scene), event \(k.id)"
                if (EventSchedule.hiddenReason(k, config: c, aspects: [aspect], at: start) != nil) != hidden {
                    out.append("\(what): Show Me has it \(hidden ? "showing" : "hidden")")
                }
                for seed in 1...24 {
                    let events = EventSchedule(seed: UInt64(seed))
                    // through the bright half of a supernova, or a comet's pass
                    var heads: [SIMD2<Double>] = []       // on screen, in half heights
                    let open = (1..<12).compactMap { i -> Bool? in
                        let t = start + k.duration * Double(i) / (k.id == EventSchedule.supernova.id ? 24 : 12)
                        let g = events.gpu(at: t, config: c, camera: cam, heightPixels: 480, demo: [k.id: start])
                        let v = k.id == EventSchedule.supernova.id ? g.snDir : g.cometHead
                        guard v.w > 0 else { return nil }
                        let d = simd_normalize(SIMD3(Double(v.x), Double(v.y), Double(v.z)))
                        let uv = cam.project(d) ?? SIMD2(2, 2)
                        heads.append(SIMD2(uv.x * aspect, uv.y))
                        return (SkyCover(c, camera: cam, at: t)?.open(d) ?? true) && (!crossing || max(abs(uv.x), abs(uv.y)) <= 1)
                    }
                    if open.isEmpty != hidden { out.append("\(what), seed \(seed): \(hidden ? "drawn" : "not drawn")") }
                    if let a = heads.first, let b = heads.last, k.id == EventSchedule.comet.id, crossing,
                       simd_distance(a, b) < 0.3 { out.append("\(what), seed \(seed): stands still") }
                    let need = crossing && k.id == EventSchedule.comet.id ? 4 : open.count * 2 / 3
                    if open.filter({ $0 }).count < need { out.append("\(what), seed \(seed): behind the scene") }
                }
            }
            return out
        }
        // Eclipse: shown or not soon after the click, either side of totality
        func eclipse() -> [String] {
            var c = WallpaperConfig()
            c.scene = .eclipse
            return [(EventSchedule.supernova, 354.0, false), (EventSchedule.supernova, 364, false), (EventSchedule.supernova, 240, true),
                    (EventSchedule.supernova, 400, true), (EventSchedule.comet, 356, false), (EventSchedule.comet, 200, true)]
                .filter { (EventSchedule.hiddenReason($0.0, config: c, aspects: [2.4], at: $0.1) != nil) != $0.2 }
                .map { "eclipse, event \($0.0.id) at \($0.1): Show Me has it \($0.2 ? "showing" : "hidden")" }
        }
        // a spot on the ringed planet's middle ring is covered only while that's nearly opaque
        func ring(_ style: RingStyle, _ density: Double, covered: Bool) -> [String] {
            var c = WallpaperConfig()
            c.scene = .ringedPlanet
            c.ringedRingStyle = style; c.ringedRingDensity = density; c.ringedTilt = 40; c.ringedRingWidth = 1.6
            let cam = Camera(c, aspect: 2.4)
            let a = SceneParams.build(c, elapsed: 0, camera: cam, width: 0, height: 0, events: EventSchedule(seed: 0), demo: [:]).a
            let n = SIMD3(Double(a.x), Double(a.y), Double(a.z)), e = simd_normalize(simd_cross(n, cam.fwd))
            let spot = e * Double(a.w) * (1.24 + (1.75 - 1.24) * 1.6)
            let open = SkyCover(c, camera: cam, at: 0)?.open(simd_normalize(spot - cam.pos)) ?? true
            return open == covered ? ["ringed planet, \(style) at \(density): the middle ring is \(open ? "open" : "covered")"] : []
        }
        return [
            eclipse(), ring(.classic, 1.6, covered: true), ring(.classic, 1, covered: false), ring(.broad, 1.6, covered: false),
            fails(.gasGiant, 1.6, crossing: true) { $0.gasDistance = 1.4; $0.gasCenterX = 0; $0.gasCenterY = -0.6 },
            fails(.gasGiant, 0.5625, crossing: true) { $0.gasDistance = 1.3; $0.gasCenterX = 0; $0.gasCenterY = 0 },
            fails(.stellarSurface, 0.5625, crossing: true) { $0.starZoom = 1.5; $0.starLimbY = 0.95 },
            fails(.auroraOrbit, 2.4), fails(.auroraOrbit, 1.6) { $0.auroraHorizon = 0.8 },
            fails(.gasGiant, 2.4),
            fails(.gasGiant, 1.6, hidden: true) { $0.gasDistance = 1.2; $0.gasCenterX = 0; $0.gasCenterY = 0 },
            fails(.stellarSurface, 2.4), fails(.stellarSurface, 2.4) { $0.starZoom = 2.2; $0.starLimbY = 0.6 },
            fails(.stellarSurface, 0.56, hidden: true) { $0.starZoom = 4; $0.starLimbY = 1; $0.starCenterX = 0 },
            fails(.eclipse, 2.4) { $0.eclipseMotion = .hold },
            fails(.eclipse, 1.6) { $0.eclipseMotion = .hold; $0.eclipsePlanetSize = 1.8; $0.eclipsePlanetY = 0.4 },
            fails(.eclipse, 2.4, hidden: true) {
                $0.eclipseMotion = .hold; $0.eclipseAtmosphere = true
                $0.eclipseAirDensity = 3; $0.eclipseAirHaze = 2; $0.eclipseClouds = 1
            },
            fails(.roguePlanet, 1.6) { $0.rogueSize = 1.8 }, fails(.ringedPlanet, 1.6), fails(.blackHole, 2.4),
        ].flatMap { $0 }
    }
}
