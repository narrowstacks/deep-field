import Foundation

struct WallpaperConfig: Codable, Equatable {
    var scene: SceneKind = .blackHole

    // Look
    var pixelSize = 3
    var levels = 5
    var dither: DitherPattern = .bayer8
    var fps = 24
    var saturation = 1.35
    var brightness = 1.15
    var palette = PaletteConfig.gargantua

    /// Set a still of the scene as the desktop picture, so the lock and login screens match.
    var lockScreenStill = false
    /// Render that still in smooth full color instead of the wallpaper's dithered pixel look.
    var lockScreenSmooth = false

    // Camera
    var tilt = 6.3                 // degrees above the disk / orbital plane

    // Black hole
    var diskSize = 15.0            // outer radius
    var diskSpeed = 1.0
    var photonRing = 1.0

    // Wormhole
    var throat = 3.5

    // Star systems
    var binaryStars: [StarType] = [.yellow, .redDwarf]
    var trinaryStars: [StarType] = [.blueGiant, .whiteDwarf, .redDwarf]
    var starOrbitMinutes = 3.0
    var starSeparation = 6.0

    // Galaxy
    var galaxyType: GalaxyType = .spiral
    var galaxyArms = 2
    var galaxyPitch = 14.0             // spiral arm pitch angle, degrees
    var galaxyView = 32.0              // viewing angle above the disk, degrees
    var galaxyRotationMinutes = 6.0    // orbital period at the visible edge (with dark matter)
    var darkMatter = true
    var galaxySize = 1.0

    // Star meets black hole (tidal disruption)
    var tdeCycleMinutes = 4.0
    var tdeStar: StarType = .yellow
    var tdeView = 14.0

    // Pulsar
    var pulsarPeriod = 3.0             // seconds per rotation
    var pulsarInclination = 40.0       // magnetic axis vs spin axis, degrees
    var pulsarAxisTilt = 25.0          // spin axis leaning toward you, degrees
    var pulsarBeamWidth = 7.0          // degrees
    var pulsarBeamColor = RGB(0.55, 0.75, 1.0)
    var pulsarNebulaColor = RGB(0.7, 0.4, 1.0)
    var pulsarNebula = true
    var pulsarFieldLines = true

    // Nebula
    var nebulaType: NebulaType = .pillars
    var nebulaSeed = 1
    var nebulaFlow = 1.0
    var nebulaHa = RGB(1.0, 0.22, 0.35)     // hydrogen alpha
    var nebulaOIII = RGB(0.15, 0.85, 0.9)   // doubly ionized oxygen
    var nebulaSII = RGB(1.0, 0.65, 0.2)     // ionized sulfur

    // Comet
    var cometTailLength = 1.0
    var cometActivity = 1.0
    var cometIonColor = RGB(0.3, 0.6, 1.0)
    var cometDustColor = RGB(1.0, 0.85, 0.6)
    var cometEvents: Frequency = .normal

    // Star close-up
    var closeStar: StarType = .yellow
    var starSpots = 1.0
    var starFlares: Frequency = .normal
    var starRotation = 1.0

    // Sky
    var starDensity = 1.0
    var nebula = 1.0
    var galaxies = true
    var milkyWay = false

    // Planets
    var planetCount = 3
    var planetSize = 1.0
    var planetOrbitMinutes = 40.0
    var planetSeed = 1

    // Events
    var twinkles: Frequency = .normal
    var pulsars = true
    var supernovae: Frequency = .normal
    var comets: Frequency = .normal
    var wormholeEvents: Frequency = .normal

    /// Camera elevation for the current scene; the galaxy and tidal disruption have their own.
    var cameraTilt: Double {
        switch scene {
        case .galaxy: galaxyView
        case .tidalDisruption: tdeView
        default: tilt
        }
    }

    /// Anything that changes the precomputed ray lookups; other changes apply on the next frame.
    /// Settings only one scene's bake reads are left at a fixed value for the other scenes, so
    /// changing them doesn't re-trace a scene that ignores them. The sky pass runs for every
    /// scene, and the pixel size sets the bake's resolution.
    struct BakeKey: Equatable {
        var scene: SceneKind, tilt: Double, diskSize: Double, throat: Double
        var starDensity: Double, galaxies: Bool, milkyWay: Bool, pixelSize: Int
        var nebulaType: NebulaType, nebulaSeed: Int
    }

    var bakeKey: BakeKey {
        BakeKey(scene: scene, tilt: cameraTilt,
                diskSize: scene == .blackHole ? diskSize : 0,     // the tidal disruption bakes a fixed disk
                throat: scene == .wormhole ? throat : 0,
                starDensity: starDensity, galaxies: galaxies, milkyWay: milkyWay, pixelSize: pixelSize,
                nebulaType: scene == .nebula ? nebulaType : .pillars, nebulaSeed: scene == .nebula ? nebulaSeed : 0)
    }

    /// Decodes leniently: keys missing from older saved configs fall back to defaults, and so
    /// does any single key that no longer decodes (say, an enum case this build doesn't know),
    /// instead of the whole config resetting.
    static func decode(_ data: Data) -> WallpaperConfig? {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(WallpaperConfig()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else { return nil }
        // merge one level deep too, so palettes saved before new colors were added still load
        func merging(_ key: String, _ value: Any, into dict: inout [String: Any]) {
            if let nested = value as? [String: Any], var base = dict[key] as? [String: Any] {
                base.merge(nested) { _, new in new }
                dict[key] = base
            } else {
                dict[key] = value
            }
        }
        func decoded(_ dict: [String: Any]) -> WallpaperConfig? {
            guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(WallpaperConfig.self, from: d)
        }
        var merged = defaults
        for (key, value) in saved { merging(key, value, into: &merged) }
        if let c = decoded(merged) { return c.sanitized() }
        // something in there is bad: keep each key only if the config still decodes with it
        merged = defaults
        for key in saved.keys.sorted() {
            var trial = merged
            merging(key, saved[key]!, into: &trial)
            if decoded(trial) != nil { merged = trial }
        }
        return decoded(merged)?.sanitized()
    }

    /// Clamps values the renderer would choke on (zero periods, missing stars, a zero pixel
    /// size). The Customize window can't produce these; a hand-edited or damaged save can.
    func sanitized() -> WallpaperConfig {
        let d = WallpaperConfig()
        var c = self
        func positive(_ kp: WritableKeyPath<WallpaperConfig, Double>, min lo: Double) {
            if !(c[keyPath: kp] >= lo) { c[keyPath: kp] = c[keyPath: kp].isNaN ? d[keyPath: kp] : lo }
        }
        c.pixelSize = min(max(c.pixelSize, 1), 16)
        c.levels = min(max(c.levels, 2), 256)
        c.fps = min(max(c.fps, 1), 120)
        c.planetCount = min(max(c.planetCount, 0), 6)
        for kp in [\WallpaperConfig.starOrbitMinutes, \.planetOrbitMinutes, \.galaxyRotationMinutes,
                   \.tdeCycleMinutes, \.pulsarPeriod, \.nebulaFlow, \.planetSize, \.galaxySize] {
            positive(kp, min: 0.05)
        }
        if c.binaryStars.count < 2 { c.binaryStars += d.binaryStars.dropFirst(c.binaryStars.count) }
        if c.trinaryStars.count < 3 { c.trinaryStars += d.trinaryStars.dropFirst(c.trinaryStars.count) }
        if c.galaxyArms < 1 { c.galaxyArms = 1 }
        return c
    }
}
