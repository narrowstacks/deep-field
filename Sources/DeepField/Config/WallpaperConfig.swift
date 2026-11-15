import Foundation

struct WallpaperConfig: Codable, Equatable {
    var scene: SceneKind = .blackHole

    // Look
    var pixelSize = 3
    var levels = 5
    var dither: DitherPattern = .bayer8
    var fps = 24
    var saturation = 1.35
    var brightness = 1.15          // the exposure: scales the scene's light before tone mapping
    var palette = PaletteConfig.gargantua

    // Image, applied to the scene's light before tone mapping and dithering. The defaults are
    // neutral apart from a light bloom.
    var contrast = 1.0
    var blackPoint = 0.0
    var highlights = 0.0           // highlight rolloff: compresses the brightest light
    var vignette = 0.0
    var bloom = 0.3                // glow amount; 0 skips the bloom passes entirely
    var bloomRadius = 0.03         // fraction of the frame's shorter side
    var bloomThreshold = 0.5       // tone-mapped brightness where the glow starts

    /// Set a still of the scene as the desktop picture, so the lock and login screens match.
    var lockScreenStill = false
    /// Render that still in smooth full color instead of the wallpaper's dithered pixel look.
    var lockScreenSmooth = false

    // Camera
    var tilt = 6.3                 // degrees above the disk / orbital plane
    /// Portrait phone framing (mobile export only). Never set on the saved config, and nil
    /// isn't encoded, so the saved format is unchanged.
    var phoneFraming: PhoneFraming?

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
    var tdeCycleMinutes = 4.0          // unused since the scene became a steady stream; kept so the key stays stable
    var tdeStar: StarType = .blueGiant
    var tdeView = 14.0
    var tdeStarSize = 1.0
    var tdeStarDistance = 20.0         // from the hole, Schwarzschild radii
    var tdeStreamBrightness = 1.0
    var tdeDiskColors: TDEDiskColors = .palette
    var tdeJets = true
    var tdeJetColor = Tuned.tdeJet.color

    // Pulsar
    var pulsarPeriod = 3.0             // seconds per rotation
    var pulsarInclination = 52.0       // magnetic axis vs spin axis, degrees
    var pulsarAxisTilt = 25.0          // spin axis leaning toward you, degrees
    var pulsarBeamWidth = 7.0          // degrees
    var pulsarBeamColor = Tuned.pulsarBeam.color
    var pulsarNebulaColor = Tuned.pulsarNebula.color
    var pulsarNebula = true
    var pulsarFieldLines = true            // the magnetic field on/off, drawn in pulsarFieldStyle
    var pulsarBeams: PulsarBeams = .both
    var pulsarFieldStyle: PulsarFieldStyle = .lines
    var pulsarRing = false                 // dust ring in the spin plane
    var pulsarFieldColor = Tuned.pulsarField.color
    var pulsarRingColor = Tuned.pulsarRing.color
    var pulsarBeamIntensity = 1.0
    var pulsarFieldIntensity = 1.0
    var pulsarRingIntensity = 1.0
    var pulsarNebulaIntensity = 1.0
    var pulsarBeamTrail = 1.0              // how far the beams wind back behind the rotation

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
    var cometIonColor = Tuned.cometIon.color
    var cometDustColor = Tuned.cometDust.color
    var cometEvents: Frequency = .normal

    // Star close-up
    var closeStar: StarType = .yellow
    var starSpots = 1.0
    var starFlares: Frequency = .normal
    var starRotation = 1.0
    var starZoom = 1.0                 // 1 = the limb close-up; about 0.45 shows the whole disk
    var starCenterX = -0.15            // disk center, fraction of the half screen width
    var starLimbY = 0.12               // top of the disk, fraction of the half screen height

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
    var planetRings = true             // some giants get rings (around the black hole and wormhole)

    // Events
    var twinkles: Frequency = .normal
    var pulsars = true
    var supernovae: Frequency = .normal
    var comets: Frequency = .normal
    var wormholeEvents: Frequency = .normal

    static let starZoomRange = 0.4...4.0

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
        var tdeStar: SIMD2<Double>          // star radius and distance (tidal disruption only)
        var phoneFraming: PhoneFraming?
    }

    var bakeKey: BakeKey {
        BakeKey(scene: scene, tilt: cameraTilt,
                diskSize: scene == .blackHole ? diskSize : 0,     // the tidal disruption bakes a fixed disk
                throat: scene == .wormhole ? throat : 0,
                starDensity: starDensity, galaxies: galaxies, milkyWay: milkyWay, pixelSize: pixelSize,
                nebulaType: scene == .nebula ? nebulaType : .pillars, nebulaSeed: scene == .nebula ? nebulaSeed : 0,
                tdeStar: scene == .tidalDisruption ? SIMD2(tdeStar.radius * tdeStarSize, tdeStarDistance) : .zero,
                phoneFraming: phoneFraming)
    }

    /// Decodes leniently: keys missing from older saved configs fall back to defaults, and so
    /// does any single key that no longer decodes (say, an enum case this build doesn't know),
    /// instead of the whole config resetting.
    static func decode(_ data: Data) -> WallpaperConfig? {
        guard var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(WallpaperConfig()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else { return nil }
        migrateTunedColors(&saved)
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
        func clamp(_ kp: WritableKeyPath<WallpaperConfig, Double>, _ r: ClosedRange<Double>) {
            let v = c[keyPath: kp]
            c[keyPath: kp] = v.isNaN ? d[keyPath: kp] : min(max(v, r.lowerBound), r.upperBound)
        }
        clamp(\.starZoom, Self.starZoomRange)
        clamp(\.starCenterX, -1...1)
        clamp(\.starLimbY, -0.9...1)
        for (kp, range) in Self.imageRanges { clamp(kp, range) }
        return c
    }
}

extension WallpaperConfig {
    static let exposureRange = 0.3...3.0
    static let contrastRange = 0.5...2.0
    static let blackPointRange = 0.0...0.3
    static let bloomRange = 0.0...3.0
    static let bloomRadiusRange = 0.005...0.12

    static let imageRanges: [(WritableKeyPath<WallpaperConfig, Double>, ClosedRange<Double>)] = [
        (\.brightness, exposureRange), (\.contrast, contrastRange), (\.blackPoint, blackPointRange),
        (\.highlights, 0...1), (\.vignette, 0...1), (\.bloom, bloomRange),
        (\.bloomRadius, bloomRadiusRange), (\.bloomThreshold, 0...1),
    ]

    /// Puts the image controls back to their neutral defaults.
    mutating func resetImage() {
        let d = WallpaperConfig()
        for (kp, _) in Self.imageRanges { self[keyPath: kp] = d[keyPath: kp] }
        saturation = d.saturation
    }
}
