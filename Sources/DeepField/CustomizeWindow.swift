import AppKit
import SwiftUI

final class CustomizeWindowController {
    static let shared = CustomizeWindowController()
    private var window: NSWindow?

    /// Dev aid: `--capture-ui out.png [tab]` opens the window, saves an image of it, and quits.
    func captureForDebug(to path: String) {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let view = self?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: CustomizeView()))
            w.title = "Customize Deep Field"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The live wallpaper renderer, embedded. Renders at the main screen's resolution and scales down.
private struct LivePreview: NSViewRepresentable {
    let reference: CGSize
    func makeNSView(context: Context) -> WallpaperView { WallpaperView(frame: .zero, previewOf: reference) }
    func updateNSView(_ nsView: WallpaperView, context: Context) {}
}

struct CustomizeView: View {
    @ObservedObject private var store = ConfigStore.shared

    private var reference: CGSize {
        guard let s = NSScreen.main else { return CGSize(width: 2880, height: 1800) }
        return CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
    }

    var body: some View {
        VStack(spacing: 0) {
            LivePreview(reference: reference)
                .aspectRatio(reference.width / reference.height, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
            TabView {
                SceneTab(store: store).tabItem { Text("Scene") }
                ColorsTab(store: store).tabItem { Text("Colors") }
                SkyTab(store: store).tabItem { Text("Sky & Events") }
                PlanetsTab(store: store).tabItem { Text("Planets") }
                DisplayTab(store: store).tabItem { Text("Display") }
            }
            .padding(12)
        }
        .frame(width: 820, height: 830)
    }
}

// MARK: - Controls

private struct SliderRow: View {
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

private struct FrequencyRow: View {
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

private struct StarPicker: View {
    let title: String
    @Binding var star: StarType
    var body: some View {
        Picker(title, selection: $star) {
            ForEach(StarType.allCases) { Text($0.title).tag($0) }
        }
    }
}

// MARK: - Tabs

private struct SceneTab: View {
    @ObservedObject var store: ConfigStore

    private func rgb(_ kp: WritableKeyPath<WallpaperConfig, RGB>) -> Binding<Color> {
        Binding(get: { Color(nsColor: store.config[keyPath: kp].nsColor) },
                set: { store.config[keyPath: kp] = RGB(NSColor($0)) })
    }

    var body: some View {
        Form {
            Section {
                Picker("Scene", selection: $store.config.scene) {
                    ForEach(SceneKind.listed) { Text($0.title).tag($0) }
                }
            }
            Section(store.config.scene.title) {
                switch store.config.scene {
                case .blackHole:
                    SliderRow(title: "Disk size", value: $store.config.diskSize, range: 8...18) { String(format: "%.1f", $0) }
                    SliderRow(title: "Disk speed", value: $store.config.diskSpeed, range: 0.1...3)
                    SliderRow(title: "Photon ring", value: $store.config.photonRing, range: 0...2)
                case .wormhole:
                    SliderRow(title: "Throat size", value: $store.config.throat, range: 1.5...5.5) { String(format: "%.1f", $0) }
                    SliderRow(title: "Rim glow", value: $store.config.photonRing, range: 0...2)
                    Text("The far side's colors are under Colors → Other universe.")
                        .font(.callout).foregroundStyle(.secondary)
                case .binary:
                    StarPicker(title: "Star A", star: $store.config.binaryStars[0])
                    StarPicker(title: "Star B", star: $store.config.binaryStars[1])
                    SliderRow(title: "Separation", value: $store.config.starSeparation, range: 3...10) { String(format: "%.1f", $0) }
                    SliderRow(title: "Orbit period", value: $store.config.starOrbitMinutes, range: 0.5...20) { String(format: "%.1f min", $0) }
                case .trinary:
                    StarPicker(title: "Inner star A", star: $store.config.trinaryStars[0])
                    StarPicker(title: "Inner star B", star: $store.config.trinaryStars[1])
                    StarPicker(title: "Outer star", star: $store.config.trinaryStars[2])
                    SliderRow(title: "Separation", value: $store.config.starSeparation, range: 3...10) { String(format: "%.1f", $0) }
                    SliderRow(title: "Inner orbit period", value: $store.config.starOrbitMinutes, range: 0.5...20) { String(format: "%.1f min", $0) }
                case .tidalDisruption:
                    StarPicker(title: "Doomed star", star: $store.config.tdeStar)
                    SliderRow(title: "Cycle length", value: $store.config.tdeCycleMinutes, range: 1...15) { String(format: "%.0f min", $0) }
                    SliderRow(title: "Viewing angle", value: $store.config.tdeView, range: 4...35) { String(format: "%.0f°", $0) }
                    Text("A star on a near-parabolic orbit is torn apart by tides at closest approach. Half its debris is flung away; the rest swings round the hole, settles into a new accretion disk, and flares before fading. Then another star wanders in.")
                        .font(.callout).foregroundStyle(.secondary)
                case .pulsar:
                    SliderRow(title: "Rotation period", value: $store.config.pulsarPeriod, range: 0.5...12) { String(format: "%.1f s", $0) }
                    SliderRow(title: "Magnetic angle", value: $store.config.pulsarInclination, range: 0...90) { String(format: "%.0f°", $0) }
                    SliderRow(title: "Spin axis tilt", value: $store.config.pulsarAxisTilt, range: -60...60) { String(format: "%.0f°", $0) }
                    SliderRow(title: "Beam width", value: $store.config.pulsarBeamWidth, range: 2...20) { String(format: "%.0f°", $0) }
                    HStack {
                        ColorPicker("Beams", selection: rgb(\.pulsarBeamColor), supportsOpacity: false)
                        ColorPicker("Nebula", selection: rgb(\.pulsarNebulaColor), supportsOpacity: false)
                    }
                    Toggle("Magnetic field lines", isOn: $store.config.pulsarFieldLines)
                    Toggle("Wind nebula (torus and jets)", isOn: $store.config.pulsarNebula)
                    Text("Real pulsars spin up to hundreds of times a second; this one is slowed way down so the beams don't strobe.")
                        .font(.callout).foregroundStyle(.secondary)
                case .nebula:
                    Picker("Type", selection: $store.config.nebulaType) {
                        ForEach(NebulaType.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Shape seed") {
                        HStack {
                            TextField("Seed", value: $store.config.nebulaSeed, format: .number).frame(width: 80)
                            Button("Generate new") { store.config.nebulaSeed = Int.random(in: 1...99_999) }
                        }
                    }
                    SliderRow(title: "Flow speed", value: $store.config.nebulaFlow, range: 0.1...4)
                    HStack {
                        ColorPicker("Hydrogen (Hα)", selection: rgb(\.nebulaHa), supportsOpacity: false)
                        ColorPicker("Oxygen (OIII)", selection: rgb(\.nebulaOIII), supportsOpacity: false)
                        ColorPicker("Sulfur (SII)", selection: rgb(\.nebulaSII), supportsOpacity: false)
                    }
                    LabeledContent("Color mapping") {
                        HStack {
                            Button("Natural") {
                                store.config.nebulaHa = RGB(1.0, 0.22, 0.35); store.config.nebulaOIII = RGB(0.15, 0.85, 0.9); store.config.nebulaSII = RGB(1.0, 0.65, 0.2)
                            }
                            Button("Hubble palette") {
                                store.config.nebulaSII = RGB(1.0, 0.35, 0.12); store.config.nebulaHa = RGB(0.35, 1.0, 0.4); store.config.nebulaOIII = RGB(0.2, 0.45, 1.0)
                            }
                        }
                    }
                case .comet:
                    SliderRow(title: "Tail length", value: $store.config.cometTailLength, range: 0.3...2)
                    SliderRow(title: "Activity", value: $store.config.cometActivity, range: 0.2...2.5)
                    HStack {
                        ColorPicker("Ion tail", selection: rgb(\.cometIonColor), supportsOpacity: false)
                        ColorPicker("Dust tail", selection: rgb(\.cometDustColor), supportsOpacity: false)
                    }
                    FrequencyRow(title: "Outbursts and tail breaks", value: $store.config.cometEvents)
                    LabeledContent("Show me") {
                        HStack {
                            Button("Outburst") { store.demo(EventSchedule.cometOutburst) }
                            Button("Tail disconnection") { store.demo(EventSchedule.tailDisconnect) }
                        }
                    }
                case .stellarSurface:
                    StarPicker(title: "Star", star: $store.config.closeStar)
                    SliderRow(title: "Sunspots", value: $store.config.starSpots, range: 0...1.5)
                    SliderRow(title: "Rotation", value: $store.config.starRotation, range: 0...4)
                    FrequencyRow(title: "Flares and ejections", value: $store.config.starFlares)
                    LabeledContent("Show me") {
                        HStack {
                            Button("Flare") { store.demo(EventSchedule.stellarFlare) }
                            Button("Coronal mass ejection") { store.demo(EventSchedule.coronalEjection) }
                        }
                    }
                case .galaxy:
                    Picker("Type", selection: $store.config.galaxyType) {
                        ForEach(GalaxyType.allCases) { Text($0.title).tag($0) }
                    }
                    if store.config.galaxyType == .spiral || store.config.galaxyType == .barred {
                        Stepper("Spiral arms: \(store.config.galaxyArms)", value: $store.config.galaxyArms, in: 1...4)
                        SliderRow(title: "Arm pitch", value: $store.config.galaxyPitch, range: 6...35) { String(format: "%.0f°", $0) }
                    }
                    SliderRow(title: "Size", value: $store.config.galaxySize, range: 0.6...1.5)
                    SliderRow(title: "Edge orbit period", value: $store.config.galaxyRotationMinutes, range: 1...30) { String(format: "%.0f min", $0) }
                    Toggle("Dark matter halo", isOn: $store.config.darkMatter)
                    Text(store.config.darkMatter
                         ? "Flat rotation curve: stars at the edge orbit as fast as those near the middle, as observed in real galaxies. The unseen halo supplies the extra gravity."
                         : "Visible mass only: orbital speed falls off like v ∝ 1/√r, so the outer disk lags far behind. This is what we'd expect without dark matter, and it doesn't match observations.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Camera") {
                if store.config.scene == .galaxy {
                    SliderRow(title: "Viewing angle", value: $store.config.galaxyView, range: 5...85) { String(format: "%.0f°", $0) }
                } else if store.config.scene == .tidalDisruption {
                    Text("Set above.").foregroundStyle(.secondary)
                } else {
                    SliderRow(title: "Tilt", value: $store.config.tilt, range: 1...25) { String(format: "%.0f°", $0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ColorsTab: View {
    @ObservedObject var store: ConfigStore

    private func color(_ kp: WritableKeyPath<PaletteConfig, RGB>) -> Binding<Color> {
        Binding(get: { Color(nsColor: store.config.palette[keyPath: kp].nsColor) },
                set: { store.config.palette[keyPath: kp] = RGB(NSColor($0)) })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Preset") {
                    HStack {
                        ForEach(PaletteConfig.presets, id: \.0) { name, palette in
                            Button(name) { store.config.palette = palette }
                        }
                    }
                }
                SliderRow(title: "Saturation", value: $store.config.saturation, range: 0...2.5)
                SliderRow(title: "Brightness", value: $store.config.brightness, range: 0.3...3)
            }
            Section("Accretion disk") {
                HStack {
                    ColorPicker("Receding side", selection: color(\.receding), supportsOpacity: false)
                    ColorPicker("Approaching side", selection: color(\.approaching), supportsOpacity: false)
                }
                HStack {
                    ColorPicker("Hot core", selection: color(\.core), supportsOpacity: false)
                    ColorPicker("Photon ring / rim", selection: color(\.ring), supportsOpacity: false)
                }
            }
            Section("Sky") {
                HStack {
                    ColorPicker("Nebula", selection: color(\.nebulaA), supportsOpacity: false)
                    ColorPicker("Nebula wisps", selection: color(\.nebulaB), supportsOpacity: false)
                    ColorPicker("Galaxies", selection: color(\.galaxy), supportsOpacity: false)
                }
                HStack {
                    ColorPicker("Warm stars", selection: color(\.starWarm), supportsOpacity: false)
                    ColorPicker("Cool stars", selection: color(\.starCool), supportsOpacity: false)
                }
            }
            Section("Galaxy") {
                HStack {
                    ColorPicker("Old stars", selection: color(\.galaxyCore), supportsOpacity: false)
                    ColorPicker("Young stars", selection: color(\.galaxyArms), supportsOpacity: false)
                }
                HStack {
                    ColorPicker("Star-forming nebulae", selection: color(\.galaxyNebula), supportsOpacity: false)
                    ColorPicker("Dust", selection: color(\.galaxyDust), supportsOpacity: false)
                }
            }
            Section("Other universe (wormhole)") {
                HStack {
                    ColorPicker("Glow", selection: color(\.farA), supportsOpacity: false)
                    ColorPicker("Wisps", selection: color(\.farB), supportsOpacity: false)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SkyTab: View {
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

private struct PlanetsTab: View {
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

private struct DisplayTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("Pixels") {
                Picker("Pixel size", selection: $store.config.pixelSize) {
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0) px").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Color levels per channel", selection: $store.config.levels) {
                    ForEach([2, 3, 4, 5, 6, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Dither pattern", selection: $store.config.dither) {
                    ForEach(DitherPattern.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Frame rate", selection: $store.config.fps) {
                    ForEach([12, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Performance")
            } footer: {
                Text("Rendering stops whenever the desktop is fully covered or the display sleeps. Low Power Mode caps it at 12 fps. Larger pixels and lower frame rates use less power.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset everything to defaults", role: .destructive) { store.config = WallpaperConfig() }
            }
        }
        .formStyle(.grouped)
    }
}
