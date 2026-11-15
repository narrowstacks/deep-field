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
                SliderRow(title: "Saturation", value: $store.config.saturation, range: 0...2.5)
                SliderRow(title: "Brightness", value: $store.config.brightness, range: 0.3...3)
            } footer: {
                Text("Showing the colors for \(scene.title). Switch scenes on the Scene tab to edit others.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
            Section("Pulsar") {
                HStack {
                    picker("Beams", \.pulsarBeamColor)
                    picker("Nebula", \.pulsarNebulaColor)
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
