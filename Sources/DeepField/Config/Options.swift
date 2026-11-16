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

/// How the protoplanetary disk is seen: starlight scattered off its surface, the dust's own
/// millimeter glow (as ALMA sees it), or both.
enum ProtoDiskLook: String, Codable, CaseIterable, Identifiable {
    case scattered, blend, alma
    var id: String { rawValue }
    var title: String {
        switch self {
        case .scattered: "Scattered light"
        case .blend: "Both"
        case .alma: "ALMA glow"
        }
    }
    /// How much the small grains hide the millimeter glow, scattered light weight, glow weight.
    var weights: SIMD3<Float> {
        switch self {
        case .scattered: SIMD3(1, 1, 0.1)
        case .blend: SIMD3(0.015, 0.5, 0.8)
        case .alma: SIMD3(0.02, 0.06, 1.2)
        }
    }
}

/// Color looks for the protoplanetary disk: dust, lit surface, star, jets (as picks), and a look.
struct ProtoDiskPreset {
    let name: String
    let look: ProtoDiskLook
    let dust: RGB, gas: RGB, star: RGB, jet: RGB

    static let all: [ProtoDiskPreset] = [
        ProtoDiskPreset(name: "Default", look: .blend, dust: WallpaperConfig.Tuned.protoDust.color,
                        gas: WallpaperConfig.Tuned.protoGas.color, star: WallpaperConfig.Tuned.protoStar.color,
                        jet: WallpaperConfig.Tuned.protoJet.color),
        ProtoDiskPreset(name: "HL Tau (ALMA)", look: .alma, dust: RGB(1.0, 0.55, 0.12), gas: RGB(0.9, 0.4, 0.2),
                        star: RGB(1.0, 0.92, 0.75), jet: RGB(1.0, 0.45, 0.3)),
        ProtoDiskPreset(name: "Scattered light", look: .scattered, dust: RGB(0.95, 0.6, 0.35), gas: RGB(0.78, 0.84, 1.0),
                        star: RGB(1.0, 0.95, 0.85), jet: RGB(1.0, 0.3, 0.4)),
        ProtoDiskPreset(name: "Infrared", look: .scattered, dust: RGB(1.0, 0.3, 0.2), gas: RGB(1.0, 0.62, 0.3),
                        star: RGB(1.0, 0.8, 0.6), jet: RGB(0.4, 0.7, 1.0)),
        ProtoDiskPreset(name: "Teal", look: .blend, dust: RGB(0.12, 0.78, 0.7), gas: RGB(0.5, 0.38, 1.0),
                        star: RGB(0.9, 0.95, 1.0), jet: RGB(1.0, 0.35, 0.75)),
    ]

    func apply(to c: inout WallpaperConfig) {
        c.protoLook = look
        c.protoDustColor = dust
        c.protoGasColor = gas
        c.protoStarColor = star
        c.protoJetColor = jet
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
