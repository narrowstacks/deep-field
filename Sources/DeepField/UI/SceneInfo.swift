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
        case .protoplanetaryDisk: "A young star in its dusty disk, ringed with gaps that forming planets have cleared, and jets from its poles."
        case .neutronMerger: "Two neutron stars spiral together, rippling the sky with gravitational waves, and merge in a kilonova."
        case .blackHoleMerger: "Two black holes spiral together, bending the starlight behind them, and merge into one that rings like a bell."
        case .dysonSwarm: "A star wrapped in rings of orbiting solar panels, its light leaking out between them."
        case .roguePlanet: "A planet adrift between the stars with no sun, seen by the starlight it blocks, its aurorae glowing."
        case .eclipse: "A total eclipse of the sun over the horizon of another world, its corona and prominences coming out as the light fades."
        case .auroraOrbit: "Aurora curtains over the night side of Earth, seen from orbit, with city lights and storms below."
        case .ringedPlanet: "A banded gas giant and its rings, each shadowing the other, with small moons in orbit."
        case .planetaryNebula: "A dying star's shed shell, lit from inside by the white dwarf left behind."
        case .comet: "A coma with jets, a blue ion tail and a curved dust tail."
        case .stellarSurface: "The limb of a star: granulation, spots, loops and eruptions."
        case .quasar: "An active galaxy whose central black hole fires two jets far out into space."
        }
    }

    /// The longer story behind a scene, shown as the tooltip on its name.
    var details: String? {
        switch self {
        case .tidalDisruption: "A star strays too close and overflows toward the hole. Tides stretch it into an egg, and a stream of its gas peels off the tip, spirals in, and feeds the accretion disk. The star, stream and jets are all bent by the hole's gravity."
        case .blackHoleMerger: "Gravitational waves carry off the pair's orbital energy, so they close in faster and faster until their shadows run together. The new, larger hole rings down, shaking off its lumps in a last burst of waves. Each hole bends the light passing it, drawing the stars behind into arcs and a ring."
        case .neutronMerger: "Gravitational waves carry off the pair's orbital energy, so they close in and orbit faster and faster: the chirp. Tides stretch them just before they touch. The merger throws out neutron-rich debris that glows from radioactive heavy elements, hot blue at first, then redder as it spreads and cools."
        case .quasar: "Gas falling into the galaxy's central black hole heats up and outshines the whole galaxy, behind a ring of dust that hides part of it. Magnetic fields fling two jets out along the spin axis at nearly the speed of light. The jet coming toward us is boosted far brighter than the one heading away, and its knots can even appear to move faster than light. Where the jets slam into intergalactic gas they puff up into huge radio lobes."
        default: nil
        }
    }
}
