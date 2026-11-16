import Foundation

enum SceneKind: String, Codable, CaseIterable, Identifiable {
    case blackHole, tidalDisruption, wormhole, binary, trinary, galaxy, pulsar, nebula, planetaryNebula, ringedPlanet, auroraOrbit, gasGiant, eclipse, comet, stellarSurface
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
        case .planetaryNebula: "Planetary Nebula"
        case .ringedPlanet: "Ringed Planet"
        case .auroraOrbit: "Aurora from Orbit"
        case .gasGiant: "Gas Giant Storms"
        case .eclipse: "Eclipse"
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
        case .planetaryNebula: 10
        case .ringedPlanet: 11
        case .auroraOrbit: 12
        case .gasGiant: 13
        case .eclipse: 19
        }
    }
    /// Scenes offered in the Customize window. The nebula scene is parked for now (its code is
    /// kept; flip this to bring it back).
    var isListed: Bool { self != .nebula }
    static var listed: [SceneKind] { allCases.filter(\.isListed) }

    /// Glow added to the global bloom setting for scenes whose look leans on it.
    /// The eclipse takes most of it back: its bright inner corona would otherwise glow across the
    /// moon's black disk.
    var extraBloom: Double {
        switch self {
        case .auroraOrbit: 0.4
        case .eclipse: -0.22
        default: 0
        }
    }

    /// Scenes that show the orbiting planets.
    var hasPlanets: Bool { [.blackHole, .wormhole, .binary, .trinary].contains(self) }
}
