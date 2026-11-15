import SwiftUI

/// How every scene's light becomes pixels: tone and glow before the dither, then the dither.
struct ImageTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        let c = $store.config
        Form {
            Section {
                SliderRow(title: "Saturation", value: c.saturation, range: 0...2.5)
                SliderRow(title: "Exposure", value: c.brightness, range: WallpaperConfig.exposureRange)
                SliderRow(title: "Contrast", value: c.contrast, range: WallpaperConfig.contrastRange)
                SliderRow(title: "Black point", value: c.blackPoint, range: WallpaperConfig.blackPointRange)
                SliderRow(title: "Highlight rolloff", value: c.highlights, range: 0...1)
                SliderRow(title: "Vignette", value: c.vignette, range: 0...1)
            } header: {
                HStack {
                    GroupHeader(title: "Tone")
                    Spacer()
                    Button("Reset") { store.config.resetImage() }
                        .controlSize(.small)
                        .help("Puts tone and glow back to their defaults")
                }
            } footer: {
                GroupFooter("For every scene, applied before the dither, so the result stays pixel-dithered.")
            }
            Section {
                SliderRow(title: "Bloom", value: c.bloom, range: WallpaperConfig.bloomRange,
                          format: { $0 == 0 ? "Off" : String(format: "%.2f", $0) })
                if store.config.bloom > 0 {
                    SliderRow(title: "Bloom radius", value: c.bloomRadius, range: WallpaperConfig.bloomRadiusRange,
                              format: { String(format: "%.1f%%", $0 * 100) })
                    SliderRow(title: "Bloom threshold", value: c.bloomThreshold, range: 0...1)
                }
            } header: {
                GroupHeader(title: "Glow")
            } footer: {
                GroupFooter("Bloom adds a glow around bright light; off, it costs nothing.")
            }
            Section {
                // label plus seven segments doesn't fit one row here, so the titles sit above
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pixel size")
                    Picker("Pixel size", selection: $store.config.pixelSize) {
                        ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color levels per channel")
                    Picker("Color levels per channel", selection: $store.config.levels) {
                        ForEach([2, 3, 4, 5, 6, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Picker("Dither pattern", selection: $store.config.dither) {
                    ForEach(DitherPattern.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                GroupHeader(title: "Pixels")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
