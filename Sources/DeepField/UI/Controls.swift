import AppKit
import SwiftUI

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text(format(value)).monospacedDigit().frame(width: 64, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

struct FrequencyRow: View {
    let title: String
    @Binding var value: Frequency
    var demo: (() -> Void)?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Picker(title, selection: $value) {
                    ForEach(Frequency.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let demo { Button("Show me", action: demo) }
            }
        }
    }
}

struct StarPicker: View {
    let title: String
    @Binding var star: StarType
    var body: some View {
        Picker(title, selection: $star) {
            ForEach(StarType.allCases) { Text($0.title).tag($0) }
        }
    }
}

extension ConfigStore {
    /// A color picker binding for an RGB setting.
    func color(_ kp: WritableKeyPath<WallpaperConfig, RGB>) -> Binding<Color> {
        Binding(get: { Color(nsColor: self.config[keyPath: kp].nsColor) },
                set: { self.config[keyPath: kp] = RGB(NSColor($0)) })
    }
}
