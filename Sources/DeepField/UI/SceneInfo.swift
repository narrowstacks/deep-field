extension SceneKind {
    /// One line under the scene's name in the Customize window.
    var blurb: String {
        switch self {
        case .blackHole: "A lensed accretion disk and photon ring. Planets bend as they pass behind."
        case .tidalDisruption: "A star stretched by tides feeds a stream of gas into the disk."
        case .wormhole: "A wormhole showing another sky through its throat, with ours bent around the rim."
        case .binary: "Two stars in orbit, with eclipses and planets lit by both."
        case .trinary: "A close pair of stars and a distant third."
        case .galaxy: "A rotating galaxy with density-wave arms and a dark matter halo."
        case .pulsar: "A spinning neutron star with lighthouse beams and a wind nebula."
        case .nebula: "Glowing gas and dark dust."
        case .gasGiant: "A giant planet close up, its bands flowing and its storms spinning."
        case .dysonSwarm: "A star wrapped in rings of orbiting solar panels, its light leaking out between them."
        case .auroraOrbit: "Aurora curtains over the night side of Earth, seen from orbit, with city lights and storms below."
        case .ringedPlanet: "A banded gas giant and its rings, each shadowing the other, with small moons in orbit."
        case .planetaryNebula: "A dying star's shed shell, lit from inside by the white dwarf left behind."
        case .comet: "A coma with jets, a blue ion tail and a curved dust tail."
        case .stellarSurface: "The limb of a star: granulation, spots, loops and eruptions."
        }
    }

    /// The longer story behind a scene, shown as the tooltip on its name.
    var details: String? {
        switch self {
        case .tidalDisruption: "A star strays too close and overflows toward the hole. Tides stretch it into an egg, and a stream of its gas peels off the tip, spirals in, and feeds the accretion disk. The star, stream and jets are all bent by the hole's gravity."
        default: nil
        }
    }
}
