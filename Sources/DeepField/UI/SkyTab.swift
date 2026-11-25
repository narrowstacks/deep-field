import SwiftUI

/// The background sky and its events, shared by every scene but one that draws the real sky.
struct SkyTab: View {
    @ObservedObject var store: ConfigStore

    private var scene: SceneKind { store.config.scene }

    var body: some View {
        Form {
            if scene.drawsRealSky {
                Section {
                    Text("\(scene.title) draws the real sky, so the shared sky settings and events don't apply to it. Its own Stars and Milky Way are under Scene.")
                        .foregroundStyle(.secondary)
                }
            } else {
                controls
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func showMe(_ kind: EventSchedule.Kind, _ name: String) {
        if let reason = store.hiddenReason(kind) {
            StageStatus.shared.flash(reason)
        } else {
            store.demo(kind)
            StageStatus.shared.flash("\(name) started")
        }
    }

    @ViewBuilder private var controls: some View {
        Section {
            SliderRow(title: "Star density", value: $store.config.starDensity, range: 0.2...3)
            SliderRow(title: "Nebula brightness", value: $store.config.nebula, range: 0...4)
            Toggle("Distant galaxies", isOn: $store.config.galaxies)
            Toggle("Milky Way band", isOn: $store.config.milkyWay)
                .help("A band of dense stars and dust across the sky")
            LabeledContent("Star field") {
                HStack {
                    TextField("Seed", value: $store.config.skySeed, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Each number is a different arrangement of stars, nebulae and galaxies. 0 is the original sky.")
                    Button("Randomize") { store.config.skySeed = Int.random(in: 1...999_999) }
                    if store.config.skySeed != 0 {
                        Button("Original") { store.config.skySeed = 0 }
                    }
                }
            }
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
            if store.config.twinkles != .off {
                SliderRow(title: "Twinkle brightness", value: $store.config.twinkleBrightness, range: 0.2...3)
                SliderRow(title: "Twinkle speed", value: $store.config.twinkleSpeed, range: 0.25...3) { String(format: "%.2fx", $0) }
                    .help("How fast twinkles come and go, and how fast each one flickers")
            }
            Toggle("Blinking stars", isOn: $store.config.pulsars)
                .help("A few stars blink on a steady beat, like distant pulsars")
            FrequencyRow(title: "Supernovae", value: $store.config.supernovae) {
                showMe(EventSchedule.supernova, "Supernova")
            }
            FrequencyRow(title: "Comets", value: $store.config.comets) {
                showMe(EventSchedule.comet, "Comet")
            }
        } header: {
            GroupHeader(title: "Events")
        } footer: {
            GroupFooter("At Normal, a supernova goes off about every 6 minutes and a comet passes about every 9. Each plays out over two to three minutes.")
        }
    }
}
