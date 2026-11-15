import SwiftUI

struct SkyTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("Background") {
                SliderRow(title: "Star density", value: $store.config.starDensity, range: 0.2...3)
                SliderRow(title: "Nebula brightness", value: $store.config.nebula, range: 0...4)
                Toggle("Distant galaxies", isOn: $store.config.galaxies)
                Toggle("Galactic band (a Milky Way of dense stars and dust)", isOn: $store.config.milkyWay)
            }
            Section {
                FrequencyRow(title: "Twinkling stars", value: $store.config.twinkles)
                Toggle("Pulsars (a few stars blink on a steady beat)", isOn: $store.config.pulsars)
                FrequencyRow(title: "Supernovae", value: $store.config.supernovae) {
                    store.demo(EventSchedule.supernova)
                }
                FrequencyRow(title: "Comets", value: $store.config.comets) {
                    store.demo(EventSchedule.comet)
                }
                if store.config.scene == .wormhole {
                    FrequencyRow(title: "Wormhole events", value: $store.config.wormholeEvents)
                    LabeledContent("Show me") {
                        HStack {
                            Button("Something falls in") { store.demo(EventSchedule.infall) }
                            Button("Something comes out") { store.demo(EventSchedule.emergence) }
                            Button("Rim flare") { store.demo(EventSchedule.throatFlare) }
                            Button("Far-side supernova") { store.demo(EventSchedule.farSupernova) }
                        }
                    }
                }
            } header: {
                Text("Occasional events")
            } footer: {
                Text("At Normal, a supernova goes off about every 6 minutes and a comet passes about every 9. Each plays out over two to three minutes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
