import SwiftUI

struct ColorsTab: View {
    @ObservedObject var store: ConfigStore

    private func color(_ kp: WritableKeyPath<PaletteConfig, RGB>) -> Binding<Color> {
        store.color((\WallpaperConfig.palette).appending(path: kp))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Preset") {
                    HStack {
                        ForEach(PaletteConfig.presets, id: \.0) { name, palette in
                            Button(name) { store.config.palette = palette }
                        }
                    }
                }
                SliderRow(title: "Saturation", value: $store.config.saturation, range: 0...2.5)
                SliderRow(title: "Brightness", value: $store.config.brightness, range: 0.3...3)
            }
            Section("Accretion disk") {
                HStack {
                    ColorPicker("Receding side", selection: color(\.receding), supportsOpacity: false)
                    ColorPicker("Approaching side", selection: color(\.approaching), supportsOpacity: false)
                }
                HStack {
                    ColorPicker("Hot core", selection: color(\.core), supportsOpacity: false)
                    ColorPicker("Photon ring / rim", selection: color(\.ring), supportsOpacity: false)
                }
            }
            Section("Sky") {
                HStack {
                    ColorPicker("Nebula", selection: color(\.nebulaA), supportsOpacity: false)
                    ColorPicker("Nebula wisps", selection: color(\.nebulaB), supportsOpacity: false)
                    ColorPicker("Galaxies", selection: color(\.galaxy), supportsOpacity: false)
                }
                HStack {
                    ColorPicker("Warm stars", selection: color(\.starWarm), supportsOpacity: false)
                    ColorPicker("Cool stars", selection: color(\.starCool), supportsOpacity: false)
                }
            }
            Section("Galaxy") {
                HStack {
                    ColorPicker("Old stars", selection: color(\.galaxyCore), supportsOpacity: false)
                    ColorPicker("Young stars", selection: color(\.galaxyArms), supportsOpacity: false)
                }
                HStack {
                    ColorPicker("Star-forming nebulae", selection: color(\.galaxyNebula), supportsOpacity: false)
                    ColorPicker("Dust", selection: color(\.galaxyDust), supportsOpacity: false)
                }
            }
            Section("Other universe (wormhole)") {
                HStack {
                    ColorPicker("Glow", selection: color(\.farA), supportsOpacity: false)
                    ColorPicker("Wisps", selection: color(\.farB), supportsOpacity: false)
                }
            }
        }
        .formStyle(.grouped)
    }
}
