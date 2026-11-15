import Foundation
import simd

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
    /// Worked out once per type, since the scenes ask for it every frame.
    var color: RGB { Self.colors[self]! }

    private static let colors = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.blackbody) })

    private var blackbody: RGB {
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
