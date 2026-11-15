import AppKit
import simd
import Combine

enum SceneKind: String, Codable, CaseIterable, Identifiable {
    case blackHole, tidalDisruption, wormhole, binary, trinary, galaxy, pulsar, nebula, comet, stellarSurface
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blackHole: "Black Hole"
        case .wormhole: "Wormhole"
        case .binary: "Binary Stars"
        case .trinary: "Trinary Stars"
        case .galaxy: "Galaxy"
        case .tidalDisruption: "Star Meets Black Hole"
        case .pulsar: "Pulsar"
        case .nebula: "Nebula"
        case .comet: "Comet"
        case .stellarSurface: "Star Close-up"
        }
    }
    var shaderIndex: Float {
        switch self {
        case .blackHole: 0
        case .wormhole: 1
        case .binary: 2
        case .trinary: 3
        case .galaxy: 4
        case .tidalDisruption: 5
        case .pulsar: 6
        case .nebula: 7
        case .comet: 8
        case .stellarSurface: 9
        }
    }
    /// Scenes offered in the Customize window. The nebula scene is parked for now (the code is
    /// kept; flip this to bring it back).
    var isListed: Bool { self != .nebula }
    static var listed: [SceneKind] { allCases.filter(\.isListed) }

    /// Scenes whose light is bent by a black hole.
    var isBlackHole: Bool { self == .blackHole || self == .tidalDisruption }
    /// Scenes that show the orbiting planets.
    var hasPlanets: Bool { [.blackHole, .wormhole, .binary, .trinary].contains(self) }
    var isStarSystem: Bool { self == .binary || self == .trinary }
}

enum GalaxyType: String, Codable, CaseIterable, Identifiable {
    case spiral, barred, elliptical, irregular, ring
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spiral: "Spiral"
        case .barred: "Barred spiral"
        case .elliptical: "Elliptical"
        case .irregular: "Irregular"
        case .ring: "Ring"
        }
    }
    var shaderIndex: Float {
        switch self {
        case .spiral: 0
        case .barred: 1
        case .elliptical: 2
        case .irregular: 3
        case .ring: 4
        }
    }
}

enum NebulaType: String, Codable, CaseIterable, Identifiable {
    case pillars, dark, emission, planetary, remnant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .emission: "Emission cloud"
        case .planetary: "Planetary nebula"
        case .remnant: "Supernova remnant"
        case .pillars: "Pillars"
        case .dark: "Dark nebula"
        }
    }
    var shaderIndex: Float {
        switch self {
        case .emission: 0
        case .planetary: 1
        case .remnant: 2
        case .pillars: 3
        case .dark: 4
        }
    }
}

enum DitherPattern: String, Codable, CaseIterable, Identifiable {
    case bayer8, bayer4, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bayer8: "Bayer 8×8 (fine)"
        case .bayer4: "Bayer 4×4 (chunky)"
        case .none: "None (posterized)"
        }
    }
    var shaderIndex: Float { self == .bayer8 ? 0 : self == .bayer4 ? 1 : 2 }
}

enum Frequency: String, Codable, CaseIterable, Identifiable {
    case off, rare, normal, often
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Events per unit time relative to normal.
    var rate: Double {
        switch self {
        case .off: 0
        case .rare: 0.4
        case .normal: 1
        case .often: 2.5
        }
    }
}

enum StarType: String, Codable, CaseIterable, Identifiable {
    case redDwarf, orangeDwarf, yellow, white, blueGiant, redGiant, whiteDwarf, neutronStar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .redDwarf: "Red dwarf"
        case .orangeDwarf: "Orange dwarf"
        case .yellow: "Yellow (Sun-like)"
        case .white: "White star"
        case .blueGiant: "Blue giant"
        case .redGiant: "Red giant"
        case .whiteDwarf: "White dwarf"
        case .neutronStar: "Neutron star"
        }
    }
    var temperature: Double {
        switch self {
        case .redDwarf: 3100
        case .orangeDwarf: 4400
        case .yellow: 5800
        case .white: 8500
        case .blueGiant: 18000
        case .redGiant: 3500
        case .whiteDwarf: 14000
        case .neutronStar: 40000
        }
    }
    /// Radius in scene units (Schwarzschild radii of the black hole scene).
    var radius: Double {
        switch self {
        case .redDwarf: 0.55
        case .orangeDwarf: 0.8
        case .yellow: 1.0
        case .white: 1.2
        case .blueGiant: 1.8
        case .redGiant: 2.5
        case .whiteDwarf: 0.28
        case .neutronStar: 0.14
        }
    }
    var mass: Double {
        switch self {
        case .redDwarf: 0.3
        case .orangeDwarf: 0.7
        case .yellow: 1
        case .white: 1.8
        case .blueGiant: 8
        case .redGiant: 1.2
        case .whiteDwarf: 0.9
        case .neutronStar: 1.4
        }
    }
    /// Corona size relative to radius; compact stars glow far beyond their tiny disks.
    var glow: Double {
        switch self {
        case .whiteDwarf: 3.0
        case .neutronStar: 5.0
        case .blueGiant: 1.4
        default: 1.0
        }
    }
    /// Sunspot coverage.
    var activity: Double {
        switch self {
        case .redDwarf, .orangeDwarf, .redGiant: 0.8
        case .yellow: 0.4
        default: 0.0
        }
    }

    /// Approximate blackbody color (Tanner Helland's fit), nudged toward saturation for the art style.
    var color: RGB {
        let t = temperature / 100
        var r, g, b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        func c(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        var rgb = SIMD3(c(r), c(g), c(b))
        let luma = (rgb * SIMD3(0.2126, 0.7152, 0.0722)).sum()
        rgb = SIMD3(repeating: luma) + (rgb - SIMD3(repeating: luma)) * 2.2
        rgb = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return RGB(Float(rgb.x), Float(rgb.y), Float(rgb.z))
    }
}

struct RGB: Codable, Equatable {
    var r: Float, g: Float, b: Float
    init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    var simd: SIMD4<Float> { SIMD4(r, g, b, 1) }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }
}

struct PaletteConfig: Codable, Equatable {
    var receding: RGB       // disk side moving away (redshifted)
    var approaching: RGB    // disk side moving toward you (blueshifted)
    var core: RGB           // hottest inner disk
    var ring: RGB           // photon ring / wormhole rim
    var nebulaA: RGB
    var nebulaB: RGB
    var farA: RGB           // wormhole's other universe
    var farB: RGB
    var starWarm: RGB
    var starCool: RGB
    var galaxy: RGB
    // galaxy scene
    var galaxyCore = RGB(1.0, 0.80, 0.52)      // old stars: bulge and smooth disk
    var galaxyArms = RGB(0.55, 0.72, 1.0)      // young blue stars in the arms
    var galaxyNebula = RGB(1.0, 0.35, 0.6)     // star-forming (H II) regions
    var galaxyDust = RGB(0.12, 0.05, 0.02)     // dust lanes

    static let gargantua = PaletteConfig(
        receding: RGB(1.0, 0.36, 0.02), approaching: RGB(0.25, 0.5, 1.0), core: RGB(1.0, 0.78, 0.45),
        ring: RGB(0.6, 0.75, 1.0), nebulaA: RGB(0.1, 0.3, 1.0), nebulaB: RGB(1.0, 0.33, 0.17),
        farA: RGB(0.85, 0.35, 1.0), farB: RGB(0.15, 0.85, 0.85),
        starWarm: RGB(1.0, 0.72, 0.45), starCool: RGB(0.55, 0.72, 1.0), galaxy: RGB(1.0, 0.85, 0.7))

    static let ember = PaletteConfig(
        receding: RGB(1.0, 0.12, 0.02), approaching: RGB(1.0, 0.7, 0.15), core: RGB(1.0, 0.92, 0.65),
        ring: RGB(1.0, 0.55, 0.25), nebulaA: RGB(0.7, 0.1, 0.05), nebulaB: RGB(1.0, 0.5, 0.1),
        farA: RGB(1.0, 0.3, 0.1), farB: RGB(1.0, 0.8, 0.3),
        starWarm: RGB(1.0, 0.6, 0.35), starCool: RGB(1.0, 0.85, 0.6), galaxy: RGB(1.0, 0.7, 0.4))

    static let glacier = PaletteConfig(
        receding: RGB(0.15, 0.45, 1.0), approaching: RGB(0.6, 1.0, 1.0), core: RGB(0.92, 0.98, 1.0),
        ring: RGB(0.8, 0.95, 1.0), nebulaA: RGB(0.1, 0.4, 1.0), nebulaB: RGB(0.4, 0.9, 1.0),
        farA: RGB(0.3, 0.6, 1.0), farB: RGB(0.7, 1.0, 0.9),
        starWarm: RGB(0.8, 0.9, 1.0), starCool: RGB(0.5, 0.75, 1.0), galaxy: RGB(0.8, 0.9, 1.0))

    static let synthwave = PaletteConfig(
        receding: RGB(1.0, 0.1, 0.55), approaching: RGB(0.1, 0.85, 1.0), core: RGB(1.0, 0.85, 1.0),
        ring: RGB(1.0, 0.45, 1.0), nebulaA: RGB(0.55, 0.1, 1.0), nebulaB: RGB(1.0, 0.2, 0.6),
        farA: RGB(1.0, 0.2, 0.7), farB: RGB(0.2, 1.0, 0.9),
        starWarm: RGB(1.0, 0.55, 0.9), starCool: RGB(0.5, 0.9, 1.0), galaxy: RGB(1.0, 0.6, 1.0))

    static let amberCRT = PaletteConfig(
        receding: RGB(1.0, 0.45, 0.0), approaching: RGB(1.0, 0.7, 0.15), core: RGB(1.0, 0.85, 0.5),
        ring: RGB(1.0, 0.7, 0.3), nebulaA: RGB(1.0, 0.5, 0.0), nebulaB: RGB(1.0, 0.6, 0.1),
        farA: RGB(1.0, 0.55, 0.05), farB: RGB(1.0, 0.75, 0.3),
        starWarm: RGB(1.0, 0.65, 0.2), starCool: RGB(1.0, 0.8, 0.45), galaxy: RGB(1.0, 0.7, 0.3))

    static let emerald = PaletteConfig(
        receding: RGB(0.05, 0.8, 0.3), approaching: RGB(0.4, 0.6, 1.0), core: RGB(0.85, 1.0, 0.8),
        ring: RGB(0.6, 1.0, 0.8), nebulaA: RGB(0.05, 0.6, 0.4), nebulaB: RGB(0.3, 0.3, 1.0),
        farA: RGB(0.9, 0.9, 0.2), farB: RGB(0.2, 0.9, 0.5),
        starWarm: RGB(0.85, 1.0, 0.7), starCool: RGB(0.6, 0.8, 1.0), galaxy: RGB(0.8, 1.0, 0.8))

    static let presets: [(String, PaletteConfig)] = [
        ("Gargantua", gargantua), ("Ember", ember), ("Glacier", glacier),
        ("Synthwave", synthwave), ("Amber CRT", amberCRT), ("Emerald", emerald),
    ]
}

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

    /// Anything that changes the precomputed ray lookups; other changes apply on the next frame.
    struct BakeKey: Equatable {
        var scene: SceneKind, tilt: Double, diskSize: Double, throat: Double
        var starDensity: Double, galaxies: Bool, milkyWay: Bool, pixelSize: Int
        var nebulaType: NebulaType, nebulaSeed: Int
    }
    /// Camera elevation for the current scene; the galaxy has its own viewing angle.
    var cameraTilt: Double {
        switch scene {
        case .galaxy: galaxyView
        case .tidalDisruption: tdeView
        default: tilt
        }
    }

    var bakeKey: BakeKey {
        BakeKey(scene: scene, tilt: cameraTilt, diskSize: diskSize, throat: throat,
                starDensity: starDensity, galaxies: galaxies, milkyWay: milkyWay, pixelSize: pixelSize,
                nebulaType: nebulaType, nebulaSeed: nebulaSeed)
    }

    /// Decodes leniently: keys missing from older saved configs fall back to defaults.
    static func decode(_ data: Data) -> WallpaperConfig? {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(WallpaperConfig()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else { return nil }
        // merge one level deep too, so palettes saved before new colors were added still load
        for (key, value) in saved {
            if let nested = value as? [String: Any], var base = merged[key] as? [String: Any] {
                base.merge(nested) { _, new in new }
                merged[key] = base
            } else {
                merged[key] = value
            }
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(WallpaperConfig.self, from: mergedData)
    }
}

/// Holds the live config, persists it, and tells every view when it changes.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    static let changed = Notification.Name("DeepFieldConfigChanged")

    private let key = "config"
    private var saveWork: DispatchWorkItem?

    @Published var config: WallpaperConfig {
        didSet {
            guard config != oldValue else { return }
            NotificationCenter.default.post(name: Self.changed, object: nil)
            scheduleSave()
        }
    }

    /// Transient "show me now" requests from the customize window: event kind id -> start time.
    @Published var demoEvents: [UInt64: Double] = [:]

    private init() {
        let d = UserDefaults.standard
        // one-time carry-over of settings saved under the app's earlier name
        if d.data(forKey: key) == nil, let old = UserDefaults(suiteName: "local.eventhorizon.wallpaper")?.data(forKey: key) {
            d.set(old, forKey: key)
        }
        if let data = d.data(forKey: key), var c = WallpaperConfig.decode(data) {
            if !c.scene.isListed { c.scene = .blackHole }
            config = c
        } else {
            var c = WallpaperConfig()
            // carry over settings from the menu-only version
            if d.integer(forKey: "fps") > 0 { c.fps = d.integer(forKey: "fps") }
            if d.integer(forKey: "pixelSize") > 0 { c.pixelSize = d.integer(forKey: "pixelSize") }
            if d.integer(forKey: "levels") > 0 { c.levels = d.integer(forKey: "levels") }
            config = c
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.config) else { return }
            UserDefaults.standard.set(data, forKey: self.key)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func demo(_ kind: EventSchedule.Kind) {
        demoEvents[kind.id] = Renderer.shared.elapsed
    }
}
