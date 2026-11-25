import AppKit
import SwiftUI

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        // One slider speaks for the whole row, so VoiceOver doesn't repeat the title and value.
        // It stands in for the pair, since a row's help is lost when the value text is hidden.
        LabeledContent {
            HStack {
                Slider(value: $value, in: range)
                Text(format(value)).monospacedDigit().frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
            }
            .accessibilityRepresentation {
                Slider(value: $value, in: range)
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value))
            }
        } label: {
            Text(title).accessibilityHidden(true)
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
                if let demo { DemoButton(title: "Show Me", action: demo) }
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
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// Buttons that start a scene's events now, two to a row.
struct DemoGrid: View {
    @ObservedObject var store: ConfigStore
    let demos: [(String, EventSchedule.Kind)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Show me").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(demos, id: \.1.id) { title, kind in
                    DemoButton(title: title) {
                        store.demo(kind)
                        StageStatus.shared.flash(title.prefix(1) + title.dropFirst().lowercased() + " started")
                    }
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
            ForEach(StarType.allCases) { s in
                Label { Text(s.title) } icon: { Image(nsImage: Self.dot(s.color.nsColor)) }
                    .tag(s)
            }
        }
    }

    /// A colored dot as a bitmap: popup menus draw images but not SwiftUI shapes, and a
    /// non-template image keeps its color there.
    private static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension ConfigStore {
    /// A color picker binding for an RGB setting.
    func color(_ kp: WritableKeyPath<WallpaperConfig, RGB>) -> Binding<Color> {
        Binding(get: { Color(nsColor: self.config[keyPath: kp].nsColor) },
                set: { self.config[keyPath: kp] = RGB(NSColor($0)) })
    }
}
