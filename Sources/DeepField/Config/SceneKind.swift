import Foundation

enum SceneKind: String, Codable, CaseIterable, Identifiable {
    case blackHole, tidalDisruption, wormhole, binary, trinary, galaxy, pulsar, nebula, comet, stellarSurface, quasar
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
        case .quasar: "Quasar"
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
        case .quasar: 16
        }
    }
    /// Scenes offered in the Customize window. The nebula scene is parked for now (its code is
    /// kept; flip this to bring it back).
    var isListed: Bool { self != .nebula }
    static var listed: [SceneKind] { allCases.filter(\.isListed) }

    /// Scenes that show the orbiting planets.
    var hasPlanets: Bool { [.blackHole, .wormhole, .binary, .trinary].contains(self) }
}
