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

/// The eclipse scene: whether the occluder keeps crossing the sun or stays parked on it.
enum EclipseMotion: String, Codable, CaseIterable, Identifiable {
    case cycle, hold
    var id: String { rawValue }
    var title: String { self == .cycle ? "Full cycle" : "Hold at totality" }
}

/// The world you stand on in the eclipse scene.
enum EclipseWorld: String, Codable, CaseIterable, Identifiable {
    case rock, ice, desert, basalt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rock: "Gray rock"
        case .ice: "Ice"
        case .desert: "Rust desert"
        case .basalt: "Volcanic basalt"
        }
    }
    var shaderIndex: Float {
        switch self {
        case .rock: 0
        case .ice: 1
        case .desert: 2
        case .basalt: 3
        }
    }
    /// Surface color (shader light) before the ground color tint.
    var base: SIMD3<Float> {
        switch self {
        case .rock: SIMD3(0.62, 0.58, 0.54)
        case .ice: SIMD3(0.56, 0.66, 0.78)
        case .desert: SIMD3(0.8, 0.42, 0.22)
        case .basalt: SIMD3(0.15, 0.14, 0.145)
        }
    }
}

/// The body hanging in the eclipse scene's sky.
enum EclipseSkyBody: String, Codable, CaseIterable, Identifiable {
    case tealGiant, bandedGiant, ringedGiant, iceGiant, rockyMoon, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tealGiant: "Teal gas giant"
        case .bandedGiant: "Banded gas giant"
        case .ringedGiant: "Ringed giant"
        case .iceGiant: "Ice giant"
        case .rockyMoon: "Cratered moon"
        case .none: "None"
        }
    }
    var shaderIndex: Float {
        switch self {
        case .tealGiant: 0
        case .bandedGiant: 1
        case .ringedGiant: 2
        case .iceGiant: 3
        case .rockyMoon: 4
        case .none: 5
        }
    }
    /// Base color (shader light) before the planet color tint.
    var base: SIMD3<Float> {
        switch self {
        case .tealGiant: SIMD3(0.3, 0.7, 0.85)
        case .bandedGiant: SIMD3(1.0, 0.8, 0.56)
        case .ringedGiant: SIMD3(0.95, 0.84, 0.62)
        case .iceGiant: SIMD3(0.55, 0.8, 0.95)
        case .rockyMoon, .none: SIMD3(0.62, 0.59, 0.55)
        }
    }
    /// Its size at size 1, relative to the teal giant (the rings reach well past the planet).
    var scale: Double {
        switch self {
        case .ringedGiant: 0.5
        case .rockyMoon: 0.55
        case .iceGiant: 0.8
        default: 1
        }
    }
}

/// Air compositions for the eclipse scene's world: sky color, density, haze and clouds.
struct EclipseAirPreset {
    let name: String
    let color: RGB, density: Double, haze: Double, clouds: Double

    static let all: [EclipseAirPreset] = [
        EclipseAirPreset(name: "Earth-like", color: RGB(0.36, 0.6, 1.0), density: 1.0, haze: 0.15, clouds: 0.5),
        EclipseAirPreset(name: "Mars-like", color: RGB(0.88, 0.64, 0.42), density: 0.35, haze: 0.8, clouds: 0.1),
        EclipseAirPreset(name: "Titan-like", color: RGB(1.0, 0.58, 0.18), density: 2.2, haze: 1.4, clouds: 0.25),
        EclipseAirPreset(name: "Sulfur", color: RGB(1.0, 0.93, 0.55), density: 1.3, haze: 0.6, clouds: 0.6),
    ]

    func matches(_ c: WallpaperConfig) -> Bool {
        c.eclipseAirColor == color && c.eclipseAirDensity == density && c.eclipseAirHaze == haze && c.eclipseClouds == clouds
    }

    func apply(to c: inout WallpaperConfig) {
        c.eclipseAirColor = color
        c.eclipseAirDensity = density
        c.eclipseAirHaze = haze
        c.eclipseClouds = clouds
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
