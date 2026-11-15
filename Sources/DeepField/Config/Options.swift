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
