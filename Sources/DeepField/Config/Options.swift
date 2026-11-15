import Foundation

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

enum RingStyle: String, Codable, CaseIterable, Identifiable {
    case classic, broad, narrow, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic"
        case .broad: "Broad"
        case .narrow: "Narrow ringlets"
        case .none: "None"
        }
    }
    var shaderIndex: Float {
        switch self {
        case .classic: 0
        case .broad: 1
        case .narrow: 2
        case .none: 3
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

/// Color looks for the ringed planet: light bands, dark bands, rings (as picks).
struct RingedPlanetPreset {
    let name: String
    let light: RGB, dark: RGB, ring: RGB

    static let all: [RingedPlanetPreset] = [
        RingedPlanetPreset(name: "Golden", light: WallpaperConfig.Tuned.ringedBandLight.color,
                           dark: WallpaperConfig.Tuned.ringedBandDark.color, ring: WallpaperConfig.Tuned.ringedRing.color),
        RingedPlanetPreset(name: "Ice", light: RGB(0.72, 0.9, 1.0), dark: RGB(0.2, 0.42, 0.72), ring: RGB(0.82, 0.9, 1.0)),
        RingedPlanetPreset(name: "Rust", light: RGB(1.0, 0.58, 0.34), dark: RGB(0.48, 0.13, 0.06), ring: RGB(0.92, 0.68, 0.5)),
        RingedPlanetPreset(name: "Violet", light: RGB(0.86, 0.68, 1.0), dark: RGB(0.32, 0.16, 0.6), ring: RGB(0.9, 0.82, 1.0)),
        RingedPlanetPreset(name: "Jade", light: RGB(0.62, 1.0, 0.82), dark: RGB(0.08, 0.42, 0.36), ring: RGB(0.86, 0.96, 0.88)),
    ]

    func apply(to c: inout WallpaperConfig) {
        c.ringedBandLight = light
        c.ringedBandDark = dark
        c.ringedRingColor = ring
    }
}

/// Color looks for the neutron star merger: the stars' glow and the kilonova as it cools (as picks).
struct MergerPreset {
    let name: String
    let star: RGB, hot: RGB, cool: RGB

    static let all: [MergerPreset] = [
        MergerPreset(name: "Kilonova", star: WallpaperConfig.Tuned.mergerStar.color,
                     hot: WallpaperConfig.Tuned.mergerHot.color, cool: WallpaperConfig.Tuned.mergerCool.color),
        MergerPreset(name: "Gold", star: RGB(1.0, 0.9, 0.7), hot: RGB(1.0, 0.86, 0.45), cool: RGB(0.85, 0.2, 0.08)),
        MergerPreset(name: "Violet", star: RGB(0.78, 0.74, 1.0), hot: RGB(0.62, 0.55, 1.0), cool: RGB(0.95, 0.15, 0.55)),
        MergerPreset(name: "Teal", star: RGB(0.7, 1.0, 0.95), hot: RGB(0.35, 0.95, 0.9), cool: RGB(0.95, 0.42, 0.2)),
    ]

    func apply(to c: inout WallpaperConfig) {
        c.mergerStarColor = star
        c.mergerHot = hot
        c.mergerCool = cool
    }
}
