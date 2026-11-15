import SwiftUI

struct PlanetsTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                Stepper("Planets: \(store.config.planetCount)", value: $store.config.planetCount, in: 0...6)
                SliderRow(title: "Size", value: $store.config.planetSize, range: 0.4...2)
                SliderRow(title: "Orbit period (outer)", value: $store.config.planetOrbitMinutes, range: 2...120) {
                    String(format: "%.0f min", $0)
                }
                LabeledContent("Arrangement") {
                    Button("Shuffle planets") { store.config.planetSeed += 1 }
                }
            } footer: {
                Text("Around the black hole and wormhole, planets are bent by gravity as they pass behind it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
