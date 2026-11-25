import simd

/// Part of `--check-customization`: sky events keep to the open sky, and Show Me's answer matches
/// whether they're drawn.
enum SkyCoverCheck {
    static func failures() -> [String] {
        func fails(_ scene: SceneKind, _ aspect: Double, hidden: Bool = false,
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
                    let open = (1..<12).compactMap { i -> Bool? in
                        let t = start + k.duration * Double(i) / (k.id == EventSchedule.supernova.id ? 24 : 12)
                        let g = events.gpu(at: t, config: c, camera: cam, heightPixels: 480, demo: [k.id: start])
                        let v = k.id == EventSchedule.supernova.id ? g.snDir : g.cometHead
                        guard v.w > 0 else { return nil }
                        let d = simd_normalize(SIMD3(Double(v.x), Double(v.y), Double(v.z)))
                        return SkyCover(c, camera: cam, at: t)?.open(d) ?? true
                    }
                    if open.isEmpty != hidden { out.append("\(what), seed \(seed): \(hidden ? "drawn" : "not drawn")") }
                    if open.filter({ $0 }).count < open.count * 2 / 3 { out.append("\(what), seed \(seed): behind the scene") }
                }
            }
            return out
        }
        return [
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
