import SwiftUI
import simd

/// Live Earth's place, time, live layers and night side, below its view controls.
struct LiveEarthSections: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var location = LocationProvider.shared

    private var frozenDate: Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: store.config.earthFrozenTime) },
                set: { store.config.earthFrozenTime = $0.timeIntervalSince1970.rounded() })
    }

    /// Only the toggle freezes at now: presets and other outside changes don't go through this
    /// setter, so they keep their date. One assignment, so the old date's clouds never download.
    private var freezeTime: Binding<Bool> {
        Binding(get: { store.config.earthFreezeTime },
                set: { on in
                    var c = store.config
                    if on && !c.earthFreezeTime { c.earthFrozenTime = Date().timeIntervalSince1970.rounded() }
                    c.earthFreezeTime = on
                    store.config = c
                })
    }

    var body: some View {
        Section {
            Toggle("Use this Mac's location", isOn: $store.config.homeFromDevice)
            if store.config.homeFromDevice {
                LabeledContent("Location") {
                    HStack {
                        Text(Self.coordinates(store.config.homeLatitude, store.config.homeLongitude))
                            .monospacedDigit().foregroundStyle(.secondary)
                        if location.updating { ProgressView().controlSize(.small) }
                        Button("Update") { location.request() }.disabled(location.updating)
                    }
                }
            } else {
                LabeledContent("Latitude") {
                    DegreesField(title: "Latitude", value: $store.config.homeLatitude, kept: WallpaperConfig.keptLatitude)
                        .help("Degrees, north positive (-90 to 90)")
                }
                LabeledContent("Longitude") {
                    DegreesField(title: "Longitude", value: $store.config.homeLongitude, kept: WallpaperConfig.keptLongitude)
                        .help("Degrees, east positive (-180 to 180)")
                }
            }
        } header: {
            GroupHeader(title: "Place")
        } footer: {
            GroupFooter(location.problem ?? "This place stays in the middle of Earth's disk, with north up.")
        }

        Section {
            Toggle("Freeze time", isOn: freezeTime)
            if store.config.earthFreezeTime {
                DatePicker("Moment", selection: frozenDate, displayedComponents: [.date, .hourAndMinute])
                LabeledContent("") {
                    Button("Now") { store.config.earthFrozenTime = Date().timeIntervalSince1970.rounded() }
                        .accessibilityLabel("Set Moment to Now")
                        .accessibilityInputLabels(["Now", "Set Moment to Now"])   // the shown word first, for Voice Control
                }
            }
        } header: {
            GroupHeader(title: "Time")
        } footer: {
            TimelineView(.periodic(from: .now, by: 60)) { _ in GroupFooter(Self.skyNote(store.config)) }
        }

        Section {
            Toggle("Live clouds", isOn: $store.config.earthClouds)
            if store.config.earthClouds {
                SliderRow(title: "Cloud cover", value: $store.config.earthCloudAmount, range: 0...1.5)
            }
            Toggle("Aurora forecast", isOn: $store.config.earthAurora)
            if store.config.earthAurora {
                SliderRow(title: "Aurora brightness", value: $store.config.earthAuroraBrightness, range: 0...3)
                SliderRow(title: "Aurora speed", value: $store.config.earthAuroraSpeed, range: 0.1...2)
                    .help("How fast the curtains ripple and drift")
            }
        } header: {
            GroupHeader(title: "Live data")
        } footer: {
            TimelineView(.periodic(from: .now, by: 60)) { _ in GroupFooter(Self.feedNote(store.config)) }
        }

        Section {
            SliderRow(title: "City lights", value: $store.config.earthCityLights, range: 0...2.5)
            SliderRow(title: "Moonlight", value: $store.config.earthMoonlight, range: 0...3)
                .help("How brightly the Moon lights the night side; it follows the Moon's phase")
        } header: {
            GroupHeader(title: "Night side")
        }
    }

    static func coordinates(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.2f° %@, %.2f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }

    /// Day or night at the place, and the Moon's phase, for the moment shown.
    static func skyNote(_ c: WallpaperConfig) -> String {
        let date = SceneParams.liveEarthDate(c)
        let home = Astronomy.point(latitude: c.homeLatitude, longitude: c.homeLongitude)
        let sunUp = asin(min(max(simd_dot(home, Astronomy.sun(date)), -1), 1)) * 180 / .pi
        let place = sunUp > 0 ? "The sun is \(Int(sunUp.rounded()))° up at the place"
            : sunUp > -18 ? "Twilight at the place" : "Night at the place"
        let moon = Int((Astronomy.moonPhase(date) * 100).rounded())
        let when = c.earthFreezeTime ? "Frozen" : "Live"
        return "\(when). \(place); the Moon is \(moon)% lit."
    }

    static func feedNote(_ c: WallpaperConfig) -> String {
        var parts: [String] = []
        for (feed, on, name) in [(LiveEarthFeeds.Feed.clouds, c.earthClouds, "Clouds"), (.aurora, c.earthAurora, "Aurora forecast")] where on {
            let s = LiveEarthFeeds.shared.status(feed)
            var text = s.fetched.map { "\(name) from \(Self.ago($0))" } ?? "\(name): the built-in map until the first download"
            if s.failed { text += " (offline, using the saved map)" }
            parts.append(text)
        }
        return parts.isEmpty ? "Clouds from geostationary weather satellites; aurora from NOAA's OVATION forecast." : parts.joined(separator: ". ") + "."
    }

    private static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// A coordinate. The setting follows the typing, always in range; the text stays as typed until
/// Return or leaving the field, since showing the kept value sooner would break up "200.5".
private struct DegreesField: View {
    let title: String
    @Binding var value: Double
    let kept: (Double) -> Double

    /// The text being typed, shown while the setting still has the value it gave.
    @State private var draft: (text: String, value: Double)?
    @FocusState private var focused: Bool

    private static let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...4))

    private var text: Binding<String> {
        Binding(get: {
            if let draft, draft.value == value { return draft.text }
            return value.formatted(Self.format)
        }, set: { new in
            // also called without a change, which mustn't round the setting to the digits shown
            guard new != self.text.wrappedValue else { return }
            var v = value
            if let typed = try? Self.format.parseStrategy.parse(new), typed.isFinite { v = kept(typed) }
            draft = (new, v)
            if v != value { value = v }
        })
    }

    var body: some View {
        TextField(title, text: text)
            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 110)
            .focused($focused)
            .onSubmit { draft = nil }
            .onChange(of: focused) { if !focused { draft = nil } }
    }
}
