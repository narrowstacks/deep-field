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
                Text(format(value)).monospacedDigit().frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

/// A frequency picker stacked under its title, so the segments fit the inspector's width.
struct FrequencyRow: View {
    let title: String
    @Binding var value: Frequency
    var demo: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if let demo { DemoButton(title: "Show me", action: demo) }
            }
            Picker(title, selection: $value) {
                ForEach(Frequency.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

struct DemoButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: "play.fill") }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// "Show me" buttons that start a scene's events now, two to a row.
struct DemoGrid: View {
    @ObservedObject var store: ConfigStore
    let demos: [(String, EventSchedule.Kind)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Show me").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(demos, id: \.1.id) { title, kind in
                    DemoButton(title: title) { store.demo(kind) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
