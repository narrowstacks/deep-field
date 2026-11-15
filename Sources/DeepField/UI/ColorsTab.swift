import SwiftUI

/// Only the colors the selected scene actually draws with, plus the background sky every scene
/// shares.
struct ColorsTab: View {
    @ObservedObject var store: ConfigStore

    private var scene: SceneKind { store.config.scene }

    private func color(_ kp: WritableKeyPath<PaletteConfig, RGB>) -> Binding<Color> {
        store.color((\WallpaperConfig.palette).appending(path: kp))
    }

    private func picker(_ title: String, _ kp: WritableKeyPath<WallpaperConfig, RGB>) -> some View {
        ColorPicker(title, selection: store.color(kp), supportsOpacity: false)
    }

    private func picker(_ title: String, palette kp: WritableKeyPath<PaletteConfig, RGB>) -> some View {
        ColorPicker(title, selection: color(kp), supportsOpacity: false)
    }

    /// Scenes whose look comes from the shared palette, so its presets mean something there.
    private var usesPalette: Bool {
        switch scene {
        case .blackHole, .wormhole: true
        case .tidalDisruption: store.config.tdeDiskColors == .palette
        default: false
        }
    }

    var body: some View {
        Form {
            Section {
                if usesPalette {
                    LabeledContent("Preset") {
                        HStack {
                            ForEach(PaletteConfig.presets, id: \.0) { name, palette in
                                Button(name) { store.config.palette = palette }
                            }
                        }
                    }
                }
            } footer: {
                Text("Showing the colors for \(scene.title). Switch scenes on the Scene tab to edit others. Each color is what that part shows where it's typically lit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ImageSection(store: store)
            sceneSections
            Section("Background sky") {
                HStack {
                    picker("Nebula", palette: \.nebulaA)
                    picker("Nebula wisps", palette: \.nebulaB)
                    picker("Galaxies", palette: \.galaxy)
                }
                HStack {
                    picker("Warm stars", palette: \.starWarm)
                    picker("Cool stars", palette: \.starCool)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var diskPickers: some View {
        HStack {
            picker("Receding side", palette: \.receding)
            picker("Approaching side", palette: \.approaching)
            picker("Hot core", palette: \.core)
        }
    }

    @ViewBuilder private var sceneSections: some View {
        switch scene {
        case .blackHole:
            Section("Accretion disk") {
                diskPickers
                picker("Photon ring", palette: \.ring)
            }
        case .tidalDisruption:
            Section("Accretion disk") {
                Picker("Disk colors", selection: $store.config.tdeDiskColors) {
                    ForEach(TDEDiskColors.allCases) { Text($0.title).tag($0) }
                }
                if store.config.tdeDiskColors == .palette { diskPickers }
                picker("Photon ring", palette: \.ring)
            }
            if store.config.tdeJets {
                Section("Jets") { picker("Jet color", \.tdeJetColor) }
            }
        case .wormhole:
            Section("Wormhole") {
                picker("Rim", palette: \.ring)
                HStack {
                    picker("Other universe glow", palette: \.farA)
                    picker("Other universe wisps", palette: \.farB)
                }
            }
        case .galaxy:
            Section("Galaxy") {
                HStack {
                    picker("Old stars", palette: \.galaxyCore)
                    picker("Young stars", palette: \.galaxyArms)
                }
                HStack {
                    picker("Star-forming nebulae", palette: \.galaxyNebula)
                    picker("Dust", palette: \.galaxyDust)
                }
            }
        case .pulsar:
            let c = store.config
            if c.pulsarBeams != .none || c.pulsarFieldLines || c.pulsarRing || c.pulsarNebula {
                Section("Pulsar") {
                    if c.pulsarBeams != .none { picker("Beams", \.pulsarBeamColor) }
                    if c.pulsarFieldLines { picker("Magnetic field", \.pulsarFieldColor) }
                    if c.pulsarRing { picker("Dust ring", \.pulsarRingColor) }
                    if c.pulsarNebula { picker("Wind nebula", \.pulsarNebulaColor) }
                }
            }
        case .comet:
            Section("Comet") {
                HStack {
                    picker("Ion tail", \.cometIonColor)
                    picker("Dust tail", \.cometDustColor)
                }
            }
        case .nebula:
            Section("Nebula") {
                HStack {
                    picker("Hydrogen (Hα)", \.nebulaHa)
                    picker("Oxygen (OIII)", \.nebulaOIII)
                    picker("Sulfur (SII)", \.nebulaSII)
                }
                LabeledContent("Color mapping") {
                    HStack {
                        Button("Natural") {
                            store.config.nebulaHa = RGB(1.0, 0.22, 0.35); store.config.nebulaOIII = RGB(0.15, 0.85, 0.9); store.config.nebulaSII = RGB(1.0, 0.65, 0.2)
                        }
                        Button("Hubble palette") {
                            store.config.nebulaSII = RGB(1.0, 0.35, 0.12); store.config.nebulaHa = RGB(0.35, 1.0, 0.4); store.config.nebulaOIII = RGB(0.2, 0.45, 1.0)
                        }
                    }
                }
            }
        case .binary, .trinary, .stellarSurface:
            Section {
                Text("This scene's stars are colored by their star type, set on the Scene tab.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Exposure, contrast, glow and the rest, applied to the scene's light before it's tone mapped
/// and dithered, for every scene.
struct ImageSection: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        let c = $store.config
        Section {
            SliderRow(title: "Exposure", value: c.brightness, range: WallpaperConfig.exposureRange)
            SliderRow(title: "Contrast", value: c.contrast, range: WallpaperConfig.contrastRange)
            SliderRow(title: "Saturation", value: c.saturation, range: 0...2.5)
            SliderRow(title: "Highlight rolloff", value: c.highlights, range: 0...1)
            SliderRow(title: "Black point", value: c.blackPoint, range: WallpaperConfig.blackPointRange)
            SliderRow(title: "Vignette", value: c.vignette, range: 0...1)
            SliderRow(title: "Bloom", value: c.bloom, range: WallpaperConfig.bloomRange,
                      format: { $0 == 0 ? "Off" : String(format: "%.2f", $0) })
            if store.config.bloom > 0 {
                SliderRow(title: "Bloom radius", value: c.bloomRadius, range: WallpaperConfig.bloomRadiusRange,
                          format: { String(format: "%.1f%%", $0 * 100) })
                SliderRow(title: "Bloom threshold", value: c.bloomThreshold, range: 0...1)
            }
        } header: {
            HStack {
                Text("Image")
                Spacer()
                Button("Reset") { store.config.resetImage() }.controlSize(.small)
            }
        } footer: {
            Text("For every scene, applied before the dither, so the result stays pixel-dithered. Bloom adds a glow around bright light; off, it costs nothing.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
