extension SceneKind {
    /// One line under the scene's name in the Customize window.
    var blurb: String {
        switch self {
        case .blackHole: "A lensed accretion disk and photon ring. Planets bend as they pass behind."
        case .tidalDisruption: "A star stretched by tides feeds a stream of gas into the disk."
        case .wormhole: "A throat to another universe, with our own sky wrapped around its rim."
        case .binary: "Two stars in orbit, with eclipses and planets lit by both."
        case .trinary: "A close pair of stars and a distant third."
        case .galaxy: "A rotating galaxy with density-wave arms and a dark matter halo."
        case .pulsar: "A spinning neutron star with lighthouse beams and a wind nebula."
        case .nebula: "Glowing gas and dark dust."
        case .comet: "A coma with jets, a blue ion tail and a curved dust tail."
        case .stellarSurface: "The limb of a star: granulation, spots, loops and eruptions."
        }
    }
}
