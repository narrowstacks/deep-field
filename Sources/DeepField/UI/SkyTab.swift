import SwiftUI

/// The background sky and its events, shared by every scene.
struct SkyTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                SliderRow(title: "Star density", value: $store.config.starDensity, range: 0.2...3)
                SliderRow(title: "Nebula brightness", value: $store.config.nebula, range: 0...4)
                Toggle("Distant galaxies", isOn: $store.config.galaxies)
                Toggle("Milky Way band", isOn: $store.config.milkyWay)
                    .help("A band of dense stars and dust across the sky")
            } header: {
                GroupHeader(title: "Background")
            }
            Section {
                SkyColors(store: store)
            } header: {
                GroupHeader(title: "Colors")
            }
            Section {
                FrequencyRow(title: "Twinkling stars", value: $store.config.twinkles)
                Toggle("Blinking stars", isOn: $store.config.pulsars)
                    .help("A few stars blink on a steady beat, like distant pulsars")
                FrequencyRow(title: "Supernovae", value: $store.config.supernovae) {
                    store.demo(EventSchedule.supernova)
                    StageStatus.shared.flash("Supernova started")
                }
                FrequencyRow(title: "Comets", value: $store.config.comets) {
                    store.demo(EventSchedule.comet)
                    StageStatus.shared.flash("Comet started")
                }
            } header: {
                GroupHeader(title: "Events")
            } footer: {
                GroupFooter("At Normal, a supernova goes off about every 6 minutes and a comet passes about every 9. Each plays out over two to three minutes.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
