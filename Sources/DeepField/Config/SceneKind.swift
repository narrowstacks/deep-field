import Foundation

enum SceneKind: String, Codable, CaseIterable, Identifiable {
    case blackHole, tidalDisruption, wormhole, binary, trinary, galaxy, pulsar, nebula, planetaryNebula, ringedPlanet, auroraOrbit, liveEarth, gasGiant, protoplanetaryDisk, neutronMerger, blackHoleMerger, dysonSwarm, roguePlanet, eclipse, quasar, comet, stellarSurface
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
        case .liveEarth: "Live Earth"
        case .gasGiant: "Gas Giant Storms"
        case .protoplanetaryDisk: "Protoplanetary Disk"
        case .neutronMerger: "Neutron Star Merger"
        case .blackHoleMerger: "Black Hole Merger"
        case .dysonSwarm: "Dyson Swarm"
        case .roguePlanet: "Rogue Planet"
        case .eclipse: "Eclipse"
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
        case .planetaryNebula: 10
        case .ringedPlanet: 11
        case .auroraOrbit: 12
        case .liveEarth: 21
        case .gasGiant: 13
        case .protoplanetaryDisk: 14
        case .neutronMerger: 15
        case .blackHoleMerger: 20
        case .dysonSwarm: 17
        case .roguePlanet: 18
        case .eclipse: 19
        case .quasar: 16
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
        case .protoplanetaryDisk, .dysonSwarm: 0.2
        case .eclipse: -0.22
        default: 0
        }
    }

    /// Draws the real sky, from a camera held over a place on Earth, so the Sky section, the shared
    /// sky events and the camera tilt have nothing to act on.
    var drawsRealSky: Bool { self == .liveEarth }

    /// Scenes with a Tilt slider, which keep their own tilt. The galaxy, tidal disruption and quasar
    /// have viewing angles instead.
    var hasTilt: Bool { !drawsRealSky && ![.galaxy, .tidalDisruption, .quasar].contains(self) }

    /// The settings a per-scene reset puts back for other scenes too, for its help.
    var sharedNote: String? {
        switch self {
        case .blackHole: "Planets are shared with Wormhole, Binary Stars and Trinary Stars, disk colors and speed with Star Meets Black Hole, and the photon ring with Wormhole and Star Meets Black Hole. They reset there too."
        case .tidalDisruption: "Disk colors and speed and the photon ring's color are shared with Black Hole, and that color with Wormhole. They reset there too."
        case .wormhole: "Planets are shared with Black Hole, Binary Stars and Trinary Stars, and the rim's glow and color are the photon ring's in Black Hole and Star Meets Black Hole. They reset there too."
        case .binary: "Planets are shared with Black Hole, Wormhole and Trinary Stars, and the separation and orbit period with Trinary Stars. They reset there too."
        case .trinary: "Planets are shared with Black Hole, Wormhole and Binary Stars, and the separation and orbit period with Binary Stars. They reset there too."
        default: nil
        }
    }

    /// Scenes that show the orbiting planets.
    var hasPlanets: Bool { [.blackHole, .wormhole, .binary, .trinary].contains(self) }
}
