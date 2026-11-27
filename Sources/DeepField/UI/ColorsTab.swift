import SwiftUI

/// One color per row: the inspector is too narrow for pickers side by side.
struct ColorRow: View {
    let title: String
    let selection: Binding<Color>

    init(_ title: String, _ selection: Binding<Color>) {
        self.title = title
        self.selection = selection
    }

    var body: some View {
        ColorPicker(title, selection: selection, supportsOpacity: false)
    }
}

extension ConfigStore {
    /// A color picker binding for a palette color.
    func color(palette kp: WritableKeyPath<PaletteConfig, RGB>) -> Binding<Color> {
        color((\WallpaperConfig.palette).appending(path: kp))
    }
}

/// Only the colors the selected scene actually draws with. Each color is what that part shows
/// where it's typically lit.
struct SceneColors: View {
    @ObservedObject var store: ConfigStore

    private var scene: SceneKind { store.config.scene }

    /// Scenes whose look comes from the shared palette, so its presets mean something there.
    private var usesPalette: Bool {
        switch scene {
        case .blackHole, .wormhole: true
        case .tidalDisruption: store.config.tdeDiskColors == .palette
        default: false
        }
    }

    /// False when the scene has no colors of its own to show, so the group can be left out.
    static func hasContent(_ c: WallpaperConfig) -> Bool {
        switch c.scene {
        case .binary, .trinary, .stellarSurface, .liveEarth: false
        case .pulsar: c.pulsarBeams != .none || c.pulsarFieldLines || c.pulsarRing || c.pulsarNebula
        default: true
        }
    }

    var body: some View {
        if usesPalette {
            PalettePresets(store: store)
        } else {
            let presets = ColorPreset.all(for: scene)
            if !presets.isEmpty {
                SwatchGrid(items: presets.map { preset in
                    .init(name: preset.name, swatches: preset.swatches, selected: preset.matches(store.config)) {
                        preset.apply(to: &store.config)
                    }
                })
            }
        }
        sceneRows
    }

    @ViewBuilder private var diskRows: some View {
        ColorRow("Receding side", store.color(palette: \.receding))
        ColorRow("Approaching side", store.color(palette: \.approaching))
        ColorRow("Hot core", store.color(palette: \.core))
    }

    @ViewBuilder private var sceneRows: some View {
        switch scene {
        case .blackHole:
            diskRows
            ColorRow("Photon ring", store.color(palette: \.ring))
        case .tidalDisruption:
            Picker("Disk colors", selection: $store.config.tdeDiskColors) {
                ForEach(TDEDiskColors.allCases) { Text($0.title).tag($0) }
            }
            if store.config.tdeDiskColors == .palette { diskRows }
            ColorRow("Photon ring", store.color(palette: \.ring))
            if store.config.tdeJets { ColorRow("Jet color", store.color(\.tdeJetColor)) }
        case .wormhole:
            ColorRow("Rim", store.color(palette: \.ring))
            ColorRow("Other universe glow", store.color(palette: \.farA))
            ColorRow("Other universe wisps", store.color(palette: \.farB))
        case .galaxy:
            ColorRow("Old stars", store.color(palette: \.galaxyCore))
            ColorRow("Young stars", store.color(palette: \.galaxyArms))
            ColorRow("Star-forming nebulae", store.color(palette: \.galaxyNebula))
            ColorRow("Dust", store.color(palette: \.galaxyDust))
        case .pulsar:
            let c = store.config
            if c.pulsarBeams != .none { ColorRow("Beams", store.color(\.pulsarBeamColor)) }
            if c.pulsarFieldLines { ColorRow("Magnetic field", store.color(\.pulsarFieldColor)) }
            if c.pulsarRing { ColorRow("Dust ring", store.color(\.pulsarRingColor)) }
            if c.pulsarNebula { ColorRow("Wind nebula", store.color(\.pulsarNebulaColor)) }
        case .gasGiant:
            ColorRow("Light zones", store.color(\.gasZone))
            ColorRow("Dark belts", store.color(\.gasBelt))
            ColorRow("Great spot", store.color(\.gasStorm))
        case .protoplanetaryDisk:
            ColorRow("Dust rings", store.color(\.protoDustColor))
            ColorRow("Lit surface", store.color(\.protoGasColor))
            ColorRow("Star", store.color(\.protoStarColor))
            if store.config.protoJets { ColorRow("Jets", store.color(\.protoJetColor)) }
        case .blackHoleMerger:
            ColorRow("Photon rings", store.color(\.bbhRingColor))
            if store.config.bbhModel != .stellar {
                let gas = store.config.bbhModel != .intermediate
                ColorRow(gas ? "Gas, hot" : "Blue stars", store.color(\.bbhHot))
                ColorRow(gas ? "Gas, cool" : "Red giants", store.color(\.bbhCool))
            }
        case .neutronMerger:
            ColorRow("Stars", store.color(\.mergerStarColor))
            ColorRow("Kilonova, hot", store.color(\.mergerHot))
            ColorRow("Kilonova, cooled", store.color(\.mergerCool))
        case .dysonSwarm:
            ColorRow("Panels", store.color(\.dysonPanelA))
            ColorRow("Panels, second finish", store.color(\.dysonPanelB))
            ColorRow("Waste heat", store.color(\.dysonHeat))
        case .roguePlanet:
            ColorRow("Aurora (low)", store.color(\.rogueAuroraLow))
            ColorRow("Aurora tops", store.color(\.rogueAuroraHigh))
            ColorRow("Rift glow", store.color(\.rogueRiftColor))
        case .eclipse:
            ColorRow("Corona", store.color(\.eclipseCoronaColor))
            ColorRow("Prominences", store.color(\.eclipseProminenceColor))
            if store.config.eclipseLandscape { ColorRow("Ground", store.color(\.eclipseGroundColor)) }
            if store.config.eclipseSkyBody != .none { ColorRow("Sky body", store.color(\.eclipsePlanetColor)) }
        case .auroraOrbit:
            ColorRow("Aurora (oxygen, low)", store.color(\.auroraGreen))
            ColorRow("Aurora tops (oxygen, high)", store.color(\.auroraRed))
            ColorRow("Lower fringe (nitrogen)", store.color(\.auroraFringe))
            ColorRow("City lights", store.color(\.auroraCityColor))
        case .ringedPlanet:
            ColorRow("Light bands", store.color(\.ringedBandLight))
            ColorRow("Dark bands", store.color(\.ringedBandDark))
            if store.config.ringedRingStyle != .none { ColorRow("Rings", store.color(\.ringedRingColor)) }
        case .planetaryNebula:
            ColorRow("Inner glow (oxygen)", store.color(\.planetaryInnerColor))
            ColorRow("Rim (hydrogen)", store.color(\.planetaryRimColor))
            if store.config.planetaryHalo { ColorRow("Halo", store.color(\.planetaryHaloColor)) }
        case .comet:
            ColorRow("Ion tail", store.color(\.cometIonColor))
            ColorRow("Dust tail", store.color(\.cometDustColor))
        case .nebula:
            ColorRow("Hydrogen (Hα)", store.color(\.nebulaHa))
            ColorRow("Oxygen (OIII)", store.color(\.nebulaOIII))
            ColorRow("Sulfur (SII)", store.color(\.nebulaSII))
        case .quasar:
            ColorRow("Jets", store.color(\.quasarJetColor))
            ColorRow("Radio lobes", store.color(\.quasarLobeColor))
        case .binary, .trinary, .stellarSurface, .liveEarth:
            EmptyView()
        }
    }
}

/// The palette presets. They leave the galaxy scene's colors alone, which have presets of their own.
struct PalettePresets: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        SwatchGrid(items: PaletteConfig.presets.map { name, preset in
            var palette = preset
            let current = store.config.palette
            palette.galaxyCore = current.galaxyCore
            palette.galaxyArms = current.galaxyArms
            palette.galaxyNebula = current.galaxyNebula
            palette.galaxyDust = current.galaxyDust
            return .init(name: name, swatches: [preset.receding, preset.core, preset.approaching, preset.nebulaA],
                         selected: current == palette) { store.config.palette = palette }
        })
    }
}

/// Color presets as swatch buttons, three to a row.
struct SwatchGrid: View {
    struct Item {
        let name: String
        let swatches: [RGB]
        let selected: Bool
        let apply: () -> Void
    }

    let items: [Item]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(items, id: \.name) { item in
                Button(action: item.apply) {
                    HStack(spacing: 6) {
                        HStack(spacing: 0) {
                            ForEach(item.swatches.indices, id: \.self) { i in
                                Rectangle().fill(Color(nsColor: item.swatches[i].nsColor)).frame(width: 10, height: 10)
                            }
                        }
                        Text(item.name).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.06))
                    .overlay(Rectangle().stroke(item.selected ? Color.accentColor : Theme.hairline,
                                                lineWidth: item.selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name) colors")
                .accessibilityInputLabels([item.name, "\(item.name) colors"])   // the shown name first, for Voice Control
                .accessibilityAddTraits(item.selected ? [.isSelected] : [])
            }
        }
    }
}

/// The background sky every scene shares.
struct SkyColors: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        ColorRow("Nebula", store.color(palette: \.nebulaA))
        ColorRow("Nebula wisps", store.color(palette: \.nebulaB))
        ColorRow("Galaxies", store.color(palette: \.galaxy))
        ColorRow("Warm stars", store.color(palette: \.starWarm))
        ColorRow("Cool stars", store.color(palette: \.starCool))
    }
}
