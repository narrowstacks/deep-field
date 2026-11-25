import Foundation

/// Everything on the Image tab: tone, glow and the pixel look.
struct ImageSettings: Codable, Equatable {
    var saturation, brightness, contrast, blackPoint, highlights, vignette: Double
    var bloom, bloomRadius, bloomThreshold: Double
    var pixelSize, levels: Int
    var dither: DitherPattern

    init(_ c: WallpaperConfig) {
        saturation = c.saturation; brightness = c.brightness; contrast = c.contrast
        blackPoint = c.blackPoint; highlights = c.highlights; vignette = c.vignette
        bloom = c.bloom; bloomRadius = c.bloomRadius; bloomThreshold = c.bloomThreshold
        pixelSize = c.pixelSize; levels = c.levels; dither = c.dither
    }

    /// Clamped the way the active scene's image settings are.
    func sanitized() -> ImageSettings {
        var c = WallpaperConfig()
        c.image = self
        return ImageSettings(c.sanitized())
    }

    /// Missing keys fall back to the defaults, so settings saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageSettings(WallpaperConfig())
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? k.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        saturation = v(.saturation, d.saturation); brightness = v(.brightness, d.brightness)
        contrast = v(.contrast, d.contrast); blackPoint = v(.blackPoint, d.blackPoint)
        highlights = v(.highlights, d.highlights); vignette = v(.vignette, d.vignette)
        bloom = v(.bloom, d.bloom); bloomRadius = v(.bloomRadius, d.bloomRadius)
        bloomThreshold = v(.bloomThreshold, d.bloomThreshold)
        pixelSize = v(.pixelSize, d.pixelSize); levels = v(.levels, d.levels); dither = v(.dither, d.dither)
    }
}

extension WallpaperConfig {
    /// The active scene's image settings (the flat fields the renderer reads).
    var image: ImageSettings {
        get { ImageSettings(self) }
        set {
            saturation = newValue.saturation; brightness = newValue.brightness; contrast = newValue.contrast
            blackPoint = newValue.blackPoint; highlights = newValue.highlights; vignette = newValue.vignette
            bloom = newValue.bloom; bloomRadius = newValue.bloomRadius; bloomThreshold = newValue.bloomThreshold
            pixelSize = newValue.pixelSize; levels = newValue.levels; dither = newValue.dither
        }
    }

    /// `self` at `other`'s place for Live Earth. Presets and preset files leave the place out
    /// unless asked: it can be where someone is.
    func withPlace(of other: WallpaperConfig) -> WallpaperConfig {
        var c = self
        c.homeLatitude = other.homeLatitude
        c.homeLongitude = other.homeLongitude
        c.homeFromDevice = other.homeFromDevice
        return c
    }

    func hasOwnImage(_ kind: SceneKind) -> Bool { sceneImage[kind.rawValue] != nil }

    /// Turns the active scene's own image settings on (starting from the shared ones) or off
    /// (going back to the shared ones and forgetting its own).
    var sceneHasOwnImage: Bool {
        get { hasOwnImage(scene) }
        set {
            guard newValue != sceneHasOwnImage else { return }
            if newValue {
                sharedImage = image
                sceneImage[scene.rawValue] = image
            } else {
                if let shared = sharedImage { image = shared }
                sceneImage[scene.rawValue] = nil
                sharedImage = nil
            }
        }
    }

    /// Called as `scene` changes: puts the old scene's image settings back where they belong,
    /// then brings in the new scene's.
    mutating func swapImage(leaving old: SceneKind) {
        let shared: ImageSettings
        if hasOwnImage(old) {
            sceneImage[old.rawValue] = image
            shared = sharedImage ?? image
        } else {
            shared = image
        }
        if let own = sceneImage[scene.rawValue] {
            sharedImage = shared
            image = own
        } else {
            sharedImage = nil
            image = shared
        }
    }
}

// MARK: per-scene reset

extension WallpaperConfig {
    /// Saved keys that belong to a scene's own settings: its Scene tab controls, colors and
    /// events. A prefix matches keys that continue with a capital letter ("gas" matches
    /// "gasWind", "pulsar" doesn't match the sky's "pulsars"). Camera tilt and the planets are
    /// shared with other scenes, so resetting one of those scenes resets them for all of them.
    private static func ownKeys(_ kind: SceneKind) -> (prefixes: [String], keys: [String], palette: [String]) {
        let planets = ["planetCount", "planetSize", "planetOrbitMinutes", "planetSeed", "planetRings"]
        let disk = ["receding", "approaching", "core", "ring"]
        switch kind {
        case .blackHole: return ([], ["diskSize", "diskSpeed", "photonRing", "tilt"] + planets, disk)
        case .wormhole: return ([], ["throat", "photonRing", "wormholeEvents", "tilt"] + planets, ["ring", "farA", "farB"])
        case .binary: return ([], ["binaryStars", "starSeparation", "starOrbitMinutes", "tilt"] + planets, [])
        case .trinary: return ([], ["trinaryStars", "starSeparation", "starOrbitMinutes", "tilt"] + planets, [])
        case .galaxy:
            return ([], ["galaxyType", "galaxyArms", "galaxyPitch", "galaxyView", "galaxyRotationMinutes", "darkMatter", "galaxySize"],
                    ["galaxyCore", "galaxyArms", "galaxyNebula", "galaxyDust"])
        case .tidalDisruption: return (["tde"], ["diskSpeed"], disk)
        case .pulsar: return (["pulsar"], ["tilt"], [])
        case .nebula: return (["nebula"], ["tilt"], [])
        case .planetaryNebula: return (["planetary"], ["tilt"], [])
        case .ringedPlanet: return (["ringed"], ["tilt"], [])
        case .auroraOrbit: return (["aurora"], ["tilt"], [])
        case .liveEarth: return (["earth"], [], [])
        case .gasGiant: return (["gas"], ["tilt"], [])
        case .protoplanetaryDisk: return (["proto"], ["tilt"], [])
        case .neutronMerger: return (["merger"], ["tilt"], [])
        case .blackHoleMerger: return (["bbh"], ["tilt"], [])
        case .dysonSwarm: return (["dyson"], ["tilt"], [])
        case .roguePlanet: return (["rogue"], ["tilt"], [])
        case .eclipse: return (["eclipse"], ["tilt"], [])
        case .quasar: return (["quasar"], [], [])
        case .comet: return (["comet"], ["tilt"], [])
        case .stellarSurface:
            return ([], ["closeStar", "starSpots", "starFlares", "starRotation", "starZoom", "starCenterX", "starLimbY", "tilt"], [])
        }
    }

    private static func owns(_ kind: SceneKind, key: String) -> Bool {
        let own = ownKeys(kind)
        if own.keys.contains(key) { return true }
        return own.prefixes.contains { p in
            key.hasPrefix(p) && key.dropFirst(p.count).first?.isUppercase == true
        }
    }

    private func jsonObject() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict
    }

    /// `self` with `kind`'s own settings put back to their defaults. Everything else (the sky,
    /// image, system settings and the other scenes) stays as it is.
    func resettingScene(_ kind: SceneKind) -> WallpaperConfig {
        var dict = jsonObject()
        let defaults = WallpaperConfig().jsonObject()
        for (key, value) in defaults where Self.owns(kind, key: key) { dict[key] = value }
        let paletteKeys = Self.ownKeys(kind).palette
        if !paletteKeys.isEmpty, var palette = dict["palette"] as? [String: Any],
           let defaultPalette = defaults["palette"] as? [String: Any] {
            for key in paletteKeys { palette[key] = defaultPalette[key] }
            dict["palette"] = palette
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let c = try? JSONDecoder().decode(WallpaperConfig.self, from: data) else { return self }
        return c
    }

    /// `kind`'s own saved keys, with its palette colors as `palette.<color>`, for the command line.
    static func sceneKeys(_ kind: SceneKind) -> [String] {
        let keys = WallpaperConfig().jsonObject().keys.filter { owns(kind, key: $0) }.sorted()
        return keys + ownKeys(kind).palette.map { "palette.\($0)" }
    }

    /// The saved settings the active scene's look depends on, for comparing two looks. It leaves out
    /// what can differ without the look being changed: the Mac's own settings, Live Earth's place
    /// (which can follow the Mac) and other scenes' settings. Going through the saved format first
    /// gives a live config and a saved one the same clamping and color migration.
    var visibleSettings: NSDictionary {
        let saved = (try? JSONEncoder().encode(self)).flatMap(Self.decode) ?? self
        var dict = saved.jsonObject()
        for key in ["fps", "lockScreenStill", "lockScreenSmooth", "homeLatitude", "homeLongitude", "homeFromDevice",
                    "sceneImage", "sharedImage", "phoneFraming"] { dict[key] = nil }
        let others = SceneKind.allCases.filter { $0 != scene }
        for key in Array(dict.keys) where !Self.owns(scene, key: key) && others.contains(where: { Self.owns($0, key: key) }) {
            dict[key] = nil
        }
        // the Sky section's settings, which a scene that draws the real sky doesn't show
        if scene.drawsRealSky {
            for key in ["starDensity", "nebula", "galaxies", "milkyWay", "skySeed", "twinkles", "twinkleBrightness",
                        "twinkleSpeed", "pulsars", "supernovae", "comets"] { dict[key] = nil }
        }
        if var palette = dict["palette"] as? [String: Any] {
            let own = Self.ownKeys(scene).palette
            for key in others.flatMap({ Self.ownKeys($0).palette }) where !own.contains(key) { palette[key] = nil }
            if scene.drawsRealSky {
                for key in ["nebulaA", "nebulaB", "galaxy", "starWarm", "starCool"] { palette[key] = nil }
            }
            dict["palette"] = palette
        }
        return dict as NSDictionary
    }

    /// True when any of `kind`'s own settings differ from their defaults.
    func isCustomized(_ kind: SceneKind) -> Bool { resettingScene(kind) != self }
}
