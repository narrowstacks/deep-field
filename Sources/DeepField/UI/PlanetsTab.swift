import SwiftUI

/// The planet rows of the Scene section, for the scenes that have planets. The caller wraps
/// them in a section.
struct PlanetsGroup: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Stepper("Planets: \(store.config.planetCount)", value: $store.config.planetCount, in: 0...6)
        SliderRow(title: "Size", value: $store.config.planetSize, range: 0.4...2)
        SliderRow(title: "Outer orbit period", value: $store.config.planetOrbitMinutes, range: 2...120) {
            String(format: "%.0f min", $0)
        }
        LabeledContent("Arrangement") {
            Button("Shuffle") { store.config.planetSeed += 1 }
        }
        Toggle("Rings on some giants", isOn: $store.config.planetRings)
    }

    static let footer = "Around the black hole and wormhole, planets bend as they pass behind. Rings show only in those two scenes."
}
