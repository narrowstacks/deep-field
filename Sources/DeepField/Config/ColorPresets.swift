import Foundation

/// A named color look for one scene: a value for each of the scene's own colors (as picks), plus
/// anything else the look needs. The black hole, wormhole and disk-colored TDE use the shared
/// palette presets instead (`PaletteConfig.presets`).
struct ColorPreset {
    typealias Field = WritableKeyPath<WallpaperConfig, RGB>

    let name: String
    let colors: [(Field, RGB)]
    var also: (inout WallpaperConfig) -> Void = { _ in }

    /// The first few colors, for the preset's button.
    var swatches: [RGB] { colors.prefix(4).map(\.1) }

    func matches(_ c: WallpaperConfig) -> Bool { colors.allSatisfy { c[keyPath: $0.0] == $0.1 } }

    func apply(to c: inout WallpaperConfig) {
        for (field, color) in colors { c[keyPath: field] = color }
        also(&c)
    }
}

extension ColorPreset {
    /// The scene's presets, its default look first; empty for scenes without their own colors.
    static func all(for scene: SceneKind) -> [ColorPreset] {
        switch scene {
        case .galaxy:
            // Dust is a tint (used as is), so it stays dark in every look.
            list([\.palette.galaxyCore, \.palette.galaxyArms, \.palette.galaxyNebula, \.palette.galaxyDust], [
                ("Starburst", [RGB(1.0, 0.85, 0.6), RGB(0.45, 0.75, 1.0), RGB(1.0, 0.2, 0.55), RGB(0.15, 0.04, 0.02)]),
                // Near infrared shows the old stars and warm dust; the arms' young stars fade.
                ("Infrared", [RGB(0.4, 0.62, 1.0), RGB(1.0, 0.45, 0.18), RGB(1.0, 0.18, 0.12), RGB(0.06, 0.02, 0.08)]),
                // Ultraviolet is all young hot stars: bright arms, a faint bulge.
                ("Ultraviolet", [RGB(0.85, 0.7, 1.0), RGB(0.5, 0.5, 1.0), RGB(0.85, 0.35, 1.0), RGB(0.04, 0.02, 0.1)]),
                ("Golden", [RGB(1.0, 0.75, 0.35), RGB(1.0, 0.88, 0.6), RGB(1.0, 0.45, 0.2), RGB(0.18, 0.07, 0.02)]),
                ("Teal", [RGB(0.75, 1.0, 0.9), RGB(0.25, 0.85, 0.9), RGB(0.9, 0.35, 1.0), RGB(0.02, 0.08, 0.1)]),
            ])
        case .pulsar:
            list([\.pulsarBeamColor, \.pulsarFieldColor, \.pulsarRingColor, \.pulsarNebulaColor], [
                ("X-ray", [RGB(0.6, 0.85, 1.0), RGB(0.4, 0.6, 1.0), RGB(0.7, 0.8, 1.0), RGB(0.35, 0.5, 1.0)]),
                // The Crab: blue-white synchrotron glow inside a shell of red and orange filaments.
                ("Crab", [RGB(1.0, 0.9, 0.8), RGB(1.0, 0.55, 0.35), RGB(1.0, 0.35, 0.15), RGB(0.45, 0.7, 1.0)]),
                ("Magnetar", [RGB(1.0, 0.4, 0.85), RGB(1.0, 0.25, 0.45), RGB(1.0, 0.6, 0.3), RGB(0.7, 0.2, 1.0)]),
                ("Emerald", [RGB(0.4, 1.0, 0.7), RGB(0.2, 0.85, 0.75), RGB(1.0, 0.8, 0.35), RGB(0.2, 0.6, 1.0)]),
                ("Solar", [RGB(1.0, 0.85, 0.5), RGB(1.0, 0.55, 0.2), RGB(1.0, 0.4, 0.2), RGB(1.0, 0.3, 0.5)]),
            ])
        case .gasGiant:
            list([\.gasZone, \.gasBelt, \.gasStorm], [
                ("Saturn", [RGB(1.0, 0.9, 0.68), RGB(0.78, 0.6, 0.38), RGB(1.0, 0.95, 0.85)]),
                // Methane absorbs red, so ice giants are blue; Neptune's storms are dark spots.
                ("Neptune", [RGB(0.5, 0.75, 1.0), RGB(0.12, 0.25, 0.75), RGB(0.08, 0.1, 0.4)]),
                ("Uranus", [RGB(0.7, 1.0, 0.95), RGB(0.35, 0.75, 0.8), RGB(0.9, 1.0, 1.0)]),
                ("Hot Jupiter", [RGB(1.0, 0.5, 0.25), RGB(0.4, 0.08, 0.06), RGB(1.0, 0.85, 0.4)]),
                ("Violet", [RGB(0.85, 0.7, 1.0), RGB(0.35, 0.15, 0.6), RGB(1.0, 0.35, 0.6)]),
            ])
        case .auroraOrbit:
            list([\.auroraGreen, \.auroraRed, \.auroraFringe, \.auroraCityColor], [
                // A strong storm: oxygen's red line takes over high up.
                ("Red storm", [RGB(1.0, 0.3, 0.3), RGB(1.0, 0.1, 0.45), RGB(1.0, 0.4, 0.8), RGB(1.0, 0.62, 0.3)]),
                // Jupiter's aurora is hydrogen, seen in ultraviolet: shown as blue and violet.
                ("Jovian", [RGB(0.55, 0.4, 1.0), RGB(1.0, 0.3, 0.8), RGB(0.3, 0.6, 1.0), RGB(1.0, 0.7, 0.4)]),
                ("Teal", [RGB(0.1, 1.0, 0.8), RGB(0.3, 0.5, 1.0), RGB(0.75, 0.3, 1.0), RGB(0.85, 0.9, 1.0)]),
                ("LED cities", [RGB(0.35, 1.0, 0.4), RGB(1.0, 0.2, 0.35), RGB(1.0, 0.3, 0.9), RGB(0.85, 0.9, 1.0)]),
                ("Gold", [RGB(1.0, 0.85, 0.3), RGB(1.0, 0.4, 0.2), RGB(1.0, 0.3, 0.6), RGB(1.0, 0.62, 0.3)]),
            ])
        case .planetaryNebula:
            list([\.planetaryInnerColor, \.planetaryRimColor, \.planetaryHaloColor], [
                ("Ring", [RGB(0.3, 0.6, 1.0), RGB(1.0, 0.45, 0.2), RGB(1.0, 0.25, 0.3)]),
                ("Cat's Eye", [RGB(0.35, 1.0, 0.6), RGB(1.0, 0.3, 0.6), RGB(0.6, 0.3, 1.0)]),
                ("Helix", [RGB(0.2, 0.85, 1.0), RGB(1.0, 0.2, 0.15), RGB(1.0, 0.5, 0.2)]),
                ("Violet", [RGB(0.75, 0.5, 1.0), RGB(1.0, 0.3, 0.75), RGB(0.4, 0.3, 1.0)]),
                ("Gold", [RGB(1.0, 0.85, 0.45), RGB(1.0, 0.4, 0.15), RGB(0.9, 0.25, 0.2)]),
            ])
        case .comet:
            list([\.cometIonColor, \.cometDustColor], [
                // Diatomic carbon gives some comets a green glow.
                ("Emerald", [RGB(0.3, 1.0, 0.6), RGB(1.0, 0.9, 0.7)]),
                ("Sungrazer", [RGB(0.5, 0.75, 1.0), RGB(1.0, 0.7, 0.35)]),
                ("Violet", [RGB(0.7, 0.45, 1.0), RGB(1.0, 0.75, 0.85)]),
                ("Teal", [RGB(0.2, 0.9, 1.0), RGB(1.0, 0.8, 0.45)]),
                ("Rose", [RGB(1.0, 0.4, 0.7), RGB(1.0, 0.85, 0.6)]),
            ])
        case .dysonSwarm:
            list([\.dysonPanelA, \.dysonPanelB, \.dysonHeat], [
                ("Gold foil", [RGB(1.0, 0.78, 0.3), RGB(1.0, 0.55, 0.15), RGB(1.0, 0.25, 0.1)]),
                ("Silicon", [RGB(0.15, 0.3, 1.0), RGB(0.2, 0.9, 1.0), RGB(1.0, 0.3, 0.2)]),
                ("Chrome", [RGB(0.9, 0.95, 1.0), RGB(0.7, 0.8, 1.0), RGB(1.0, 0.45, 0.15)]),
                ("Copper", [RGB(1.0, 0.5, 0.2), RGB(0.1, 1.0, 0.7), RGB(1.0, 0.2, 0.3)]),
                ("Violet", [RGB(0.7, 0.4, 1.0), RGB(1.0, 0.4, 0.7), RGB(1.0, 0.15, 0.4)]),
            ])
        case .roguePlanet:
            list([\.rogueAuroraLow, \.rogueAuroraHigh, \.rogueRiftColor], [
                ("Classic", [RGB(0.2, 1.0, 0.4), RGB(1.0, 0.2, 0.35), RGB(1.0, 0.55, 0.15)]),
                // Cryovolcanic: the rifts vent cold blue rather than lava.
                ("Ice", [RGB(0.3, 0.8, 1.0), RGB(0.6, 0.4, 1.0), RGB(0.4, 0.9, 1.0)]),
                ("Magma", [RGB(1.0, 0.5, 0.2), RGB(1.0, 0.15, 0.4), RGB(1.0, 0.3, 0.05)]),
                ("Toxic", [RGB(0.7, 1.0, 0.2), RGB(0.2, 1.0, 0.8), RGB(0.9, 1.0, 0.3)]),
                ("Rose", [RGB(1.0, 0.45, 0.75), RGB(1.0, 0.8, 0.4), RGB(0.4, 0.9, 1.0)]),
            ])
        case .eclipse:
            list([\.eclipseCoronaColor, \.eclipseProminenceColor], [
                ("Violet", [RGB(0.8, 0.5, 1.0), RGB(1.0, 0.3, 0.6)]),
                ("Golden", [RGB(1.0, 0.85, 0.55), RGB(1.0, 0.35, 0.15)]),
                ("Red dwarf", [RGB(1.0, 0.55, 0.35), RGB(1.0, 0.2, 0.2)]),
                ("Blue giant", [RGB(0.3, 0.7, 1.0), RGB(0.6, 0.35, 1.0)]),
                ("Emerald", [RGB(0.6, 1.0, 0.85), RGB(1.0, 0.4, 0.6)]),
            ])
        case .quasar:
            list([\.quasarJetColor, \.quasarLobeColor], [
                ("X-ray", [RGB(0.62, 0.88, 1.0), RGB(0.3, 0.45, 1.0)]),
                ("Optical", [RGB(1.0, 0.85, 0.6), RGB(1.0, 0.42, 0.25)]),
                ("Infrared", [RGB(1.0, 0.55, 0.3), RGB(1.0, 0.2, 0.25)]),
                ("Teal", [RGB(0.3, 1.0, 0.85), RGB(0.4, 0.4, 1.0)]),
                ("Violet", [RGB(0.8, 0.6, 1.0), RGB(0.55, 0.2, 1.0)]),
            ], defaultName: "Radio")
        case .ringedPlanet:
            list([\.ringedBandLight, \.ringedBandDark, \.ringedRingColor], [
                ("Ice", [RGB(0.72, 0.9, 1.0), RGB(0.2, 0.42, 0.72), RGB(0.82, 0.9, 1.0)]),
                ("Rust", [RGB(1.0, 0.58, 0.34), RGB(0.48, 0.13, 0.06), RGB(0.92, 0.68, 0.5)]),
                ("Violet", [RGB(0.86, 0.68, 1.0), RGB(0.32, 0.16, 0.6), RGB(0.9, 0.82, 1.0)]),
                ("Jade", [RGB(0.62, 1.0, 0.82), RGB(0.08, 0.42, 0.36), RGB(0.86, 0.96, 0.88)]),
                ("Rose", [RGB(1.0, 0.75, 0.8), RGB(0.55, 0.15, 0.3), RGB(1.0, 0.88, 0.9)]),
            ], defaultName: "Golden")
        case .blackHoleMerger:
            list([\.bbhRingColor, \.bbhHot, \.bbhCool], [
                ("Gold", [RGB(1.0, 0.85, 0.55), RGB(1.0, 0.9, 0.6), RGB(1.0, 0.4, 0.12)]),
                ("Violet", [RGB(0.78, 0.62, 1.0), RGB(0.6, 0.55, 1.0), RGB(1.0, 0.25, 0.6)]),
                ("Teal", [RGB(0.45, 1.0, 0.9), RGB(0.4, 0.95, 1.0), RGB(1.0, 0.5, 0.3)]),
                ("Ember", [RGB(1.0, 0.55, 0.35), RGB(1.0, 0.75, 0.45), RGB(0.8, 0.12, 0.1)]),
                // the Event Horizon Telescope's false-color images of M87* and Sgr A*
                ("EHT", [RGB(1.0, 0.62, 0.2), RGB(1.0, 0.8, 0.35), RGB(0.78, 0.15, 0.04)]),
            ], defaultName: "Ice")
        case .neutronMerger:
            list([\.mergerStarColor, \.mergerHot, \.mergerCool], [
                ("Gold", [RGB(1.0, 0.9, 0.7), RGB(1.0, 0.86, 0.45), RGB(0.85, 0.2, 0.08)]),
                ("Violet", [RGB(0.78, 0.74, 1.0), RGB(0.62, 0.55, 1.0), RGB(0.95, 0.15, 0.55)]),
                ("Teal", [RGB(0.7, 1.0, 0.95), RGB(0.35, 0.95, 0.9), RGB(0.95, 0.42, 0.2)]),
                ("Ember", [RGB(1.0, 0.75, 0.5), RGB(1.0, 0.6, 0.3), RGB(0.7, 0.05, 0.1)]),
            ], defaultName: "Kilonova")
        case .protoplanetaryDisk:
            // Each look also picks which light the disk is seen in.
            list([\.protoDustColor, \.protoGasColor, \.protoStarColor, \.protoJetColor], [
                ("HL Tau", [RGB(1.0, 0.55, 0.12), RGB(0.9, 0.4, 0.2), RGB(1.0, 0.92, 0.75), RGB(1.0, 0.45, 0.3)]),
                ("Scattered", [RGB(0.95, 0.6, 0.35), RGB(0.78, 0.84, 1.0), RGB(1.0, 0.95, 0.85), RGB(1.0, 0.3, 0.4)]),
                ("Infrared", [RGB(1.0, 0.3, 0.2), RGB(1.0, 0.62, 0.3), RGB(1.0, 0.8, 0.6), RGB(0.4, 0.7, 1.0)]),
                ("Teal", [RGB(0.12, 0.78, 0.7), RGB(0.5, 0.38, 1.0), RGB(0.9, 0.95, 1.0), RGB(1.0, 0.35, 0.75)]),
                ("Violet", [RGB(0.75, 0.35, 1.0), RGB(0.35, 0.75, 1.0), RGB(1.0, 0.95, 0.9), RGB(1.0, 0.5, 0.3)]),
            ], looks: [.blend, .alma, .scattered, .scattered, .blend, .blend])
        case .nebula:
            // The nebula's colors are shader light, not picks.
            list([\.nebulaHa, \.nebulaOIII, \.nebulaSII], [
                ("Hubble", [RGB(0.35, 1.0, 0.4), RGB(0.2, 0.45, 1.0), RGB(1.0, 0.35, 0.12)]),
            ], defaultName: "Natural")
        case .blackHole, .wormhole, .tidalDisruption, .binary, .trinary, .stellarSurface, .liveEarth:
            []
        }
    }

    /// The default look (from a fresh config) followed by `entries`, each giving `fields` in order.
    /// `looks`, when given, sets the protoplanetary disk's look for each preset, default first.
    private static func list(_ fields: [Field], _ entries: [(String, [RGB])], defaultName: String = "Default",
                             looks: [ProtoDiskLook]? = nil) -> [ColorPreset] {
        let defaults = WallpaperConfig()
        let all = [(defaultName, fields.map { defaults[keyPath: $0] })] + entries
        return all.enumerated().map { i, entry in
            var preset = ColorPreset(name: entry.0, colors: Array(zip(fields, entry.1)))
            if let look = looks?[i] { preset.also = { $0.protoLook = look } }
            return preset
        }
    }
}
