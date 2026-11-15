import SwiftUI

/// Everything about the selected scene: its parameters, framing, colors, events, planets and
/// camera. The scene itself is picked in the stage's gallery.
struct SceneTab: View {
    @ObservedObject var store: ConfigStore

    // UI state only, stored beside (not inside) the saved config
    @AppStorage("ui.collapsed.planets") private var planetsCollapsed = false
    @AppStorage("ui.collapsed.camera") private var cameraCollapsed = false

    private var scene: SceneKind { store.config.scene }

    /// A short note under the scene's own controls, where one helps.
    private var note: String? {
        switch scene {
        case .binary, .trinary, .stellarSurface: "Star colors follow the star type."
        case .pulsar: "Slowed down from hundreds of turns a second so the beams don't strobe."
        case .galaxy: store.config.darkMatter
            ? "Outer stars orbit as fast as inner ones, as observed in real galaxies."
            : "Without dark matter the outer disk lags behind. Real galaxies don't do this."
        default: nil
        }
    }

    var body: some View {
        Form {
            Section {
                switch store.config.scene {
                case .blackHole:
                    SliderRow(title: "Disk size", value: $store.config.diskSize, range: 8...18) { String(format: "%.1f", $0) }
                    SliderRow(title: "Disk speed", value: $store.config.diskSpeed, range: 0.1...3)
                    SliderRow(title: "Photon ring", value: $store.config.photonRing, range: 0...2)
                case .wormhole:
                    SliderRow(title: "Throat size", value: $store.config.throat, range: 1.5...5.5) { String(format: "%.1f", $0) }
                    SliderRow(title: "Rim glow", value: $store.config.photonRing, range: 0...2)
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
                    StarPicker(title: "Star", star: $store.config.tdeStar)
                    SliderRow(title: "Star size", value: $store.config.tdeStarSize, range: 0.5...1.6)
                    SliderRow(title: "Star distance", value: $store.config.tdeStarDistance, range: 16...28) { String(format: "%.0f", $0) }
                    SliderRow(title: "Stream brightness", value: $store.config.tdeStreamBrightness, range: 0...2)
                        .help("Gas peeled off the star, spiraling into the disk")
                    SliderRow(title: "Disk speed", value: $store.config.diskSpeed, range: 0.1...3)
                    Toggle("Jets", isOn: $store.config.tdeJets)
                case .pulsar:
                    SliderRow(title: "Rotation period", value: $store.config.pulsarPeriod, range: 0.5...12) { String(format: "%.1f s", $0) }
                        .help("Real pulsars spin up to hundreds of times a second. This one is slowed down so the beams don't strobe.")
                    SliderRow(title: "Magnetic angle", value: $store.config.pulsarInclination, range: 0...90) { String(format: "%.0f°", $0) }
                    SliderRow(title: "Spin axis tilt", value: $store.config.pulsarAxisTilt, range: -60...60) { String(format: "%.0f°", $0) }
                    Picker("Beams", selection: $store.config.pulsarBeams) {
                        ForEach(PulsarBeams.allCases) { Text($0.title).tag($0) }
                    }
                    if store.config.pulsarBeams != .none {
                        SliderRow(title: "Beam width", value: $store.config.pulsarBeamWidth, range: 2...20) { String(format: "%.0f°", $0) }
                        SliderRow(title: "Beam brightness", value: $store.config.pulsarBeamIntensity, range: 0.2...3)
                        SliderRow(title: "Beam trail", value: $store.config.pulsarBeamTrail, range: 0...3)
                    }
                    Toggle("Magnetic field", isOn: $store.config.pulsarFieldLines)
                    if store.config.pulsarFieldLines {
                        Picker("Field style", selection: $store.config.pulsarFieldStyle) {
                            ForEach(PulsarFieldStyle.allCases) { Text($0.title).tag($0) }
                        }
                        SliderRow(title: "Field brightness", value: $store.config.pulsarFieldIntensity, range: 0.2...3)
                    }
                    Toggle("Dust ring", isOn: $store.config.pulsarRing)
                    if store.config.pulsarRing {
                        SliderRow(title: "Ring brightness", value: $store.config.pulsarRingIntensity, range: 0.2...3)
                    }
                    Toggle("Wind nebula", isOn: $store.config.pulsarNebula)
                        .help("The torus and jets around the pulsar")
                    if store.config.pulsarNebula {
                        SliderRow(title: "Nebula brightness", value: $store.config.pulsarNebulaIntensity, range: 0.2...3)
                    }
                case .nebula:
                    Picker("Type", selection: $store.config.nebulaType) {
                        ForEach(NebulaType.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Shape seed") {
                        HStack {
                            TextField("Seed", value: $store.config.nebulaSeed, format: .number).frame(width: 80)
                            Button("New Shape") { store.config.nebulaSeed = Int.random(in: 1...99_999) }
                        }
                    }
                    SliderRow(title: "Flow speed", value: $store.config.nebulaFlow, range: 0.1...4)
                case .planetaryNebula:
                    SliderRow(title: "Size", value: $store.config.planetarySize, range: 0.6...1.5)
                    SliderRow(title: "Elongation", value: $store.config.planetaryElongation, range: 1...2.2) { String(format: "%.1f", $0) }
                        .help("How much longer the barrel of gas is than it is wide")
                    SliderRow(title: "Viewing angle", value: $store.config.planetaryView, range: 0...85) { String(format: "%.0f°", $0) }
                        .help("0° looks straight down the barrel and shows a round ring")
                    SliderRow(title: "Knots", value: $store.config.planetaryKnots, range: 0...1.5)
                        .help("Dense droplets of gas around the inner rim, lit on the side facing the star")
                    Toggle("Halo", isOn: $store.config.planetaryHalo)
                        .help("Faint older shells from earlier puffs, drifting outward")
                case .comet:
                    SliderRow(title: "Tail length", value: $store.config.cometTailLength, range: 0.3...2)
                    SliderRow(title: "Activity", value: $store.config.cometActivity, range: 0.2...2.5)
                case .stellarSurface:
                    StarPicker(title: "Star", star: $store.config.closeStar)
                    SliderRow(title: "Sunspots", value: $store.config.starSpots, range: 0...1.5)
                    SliderRow(title: "Rotation", value: $store.config.starRotation, range: 0...4)
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
                        .help(store.config.darkMatter
                              ? "A flat rotation curve: stars at the edge orbit as fast as those near the middle, as observed in real galaxies. The unseen halo supplies the extra gravity."
                              : "Visible mass only: orbital speed falls off like v ∝ 1/√r, so the outer disk lags far behind. Real galaxies don't do this.")
                }
            } header: {
                // the scene itself heads its first group
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text(scene.blurb).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textCase(nil)
                .padding(.bottom, 4)
                .help(scene.details ?? "")
            } footer: {
                if let note { GroupFooter(note) }
            }
            if scene == .stellarSurface {
                Section {
                    SliderRow(title: "Zoom", value: $store.config.starZoom, range: WallpaperConfig.starZoomRange)
                    SliderRow(title: "Horizontal position", value: $store.config.starCenterX, range: -1...1)
                    SliderRow(title: "Top of the star", value: $store.config.starLimbY, range: -0.9...1)
                    LabeledContent("Framing") {
                        HStack {
                            Button("Whole Star") { frameStar(zoom: 0.45, x: 0, top: 0.8) }
                            Button("Limb") { frameStar(zoom: 1, x: -0.15, top: 0.12) }
                            Button("Close-Up") { frameStar(zoom: 3, x: -0.1, top: -0.2) }
                        }
                    }
                } header: {
                    GroupHeader(title: "Framing")
                }
            }
            if SceneColors.hasContent(store.config) {
                Section {
                    SceneColors(store: store)
                } header: {
                    GroupHeader(title: "Colors")
                }
            }
            events
            if scene.hasPlanets {
                Section {
                    if !planetsCollapsed { PlanetsGroup(store: store) }
                } header: {
                    CollapsibleHeader(title: "Planets", collapsed: $planetsCollapsed)
                } footer: {
                    if !planetsCollapsed { GroupFooter(PlanetsGroup.footer) }
                }
            }
            Section {
                if !cameraCollapsed { camera }
            } header: {
                CollapsibleHeader(title: "Camera", collapsed: $cameraCollapsed)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var camera: some View {
        switch scene {
        case .galaxy:
            SliderRow(title: "Viewing angle", value: $store.config.galaxyView, range: 5...85) { String(format: "%.0f°", $0) }
        case .tidalDisruption:
            SliderRow(title: "Viewing angle", value: $store.config.tdeView, range: 4...35) { String(format: "%.0f°", $0) }
        default:
            SliderRow(title: "Tilt", value: $store.config.tilt, range: 1...25) { String(format: "%.0f°", $0) }
        }
    }

    /// The scene's own occasional events, for the scenes that have them.
    @ViewBuilder private var events: some View {
        switch scene {
        case .comet:
            Section {
                FrequencyRow(title: "Outbursts and tail breaks", value: $store.config.cometEvents)
                DemoGrid(store: store, demos: [("Outburst", EventSchedule.cometOutburst),
                                               ("Tail Disconnection", EventSchedule.tailDisconnect)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .stellarSurface:
            Section {
                FrequencyRow(title: "Flares and eruptions", value: $store.config.starFlares)
                DemoGrid(store: store, demos: [("Flare", EventSchedule.stellarFlare),
                                               ("Surge", EventSchedule.surge),
                                               ("Prominence Eruption", EventSchedule.prominenceEruption),
                                               ("Coronal Mass Ejection", EventSchedule.coronalEjection)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .planetaryNebula:
            Section {
                FrequencyRow(title: "Shell ejections", value: $store.config.planetaryEvents)
                DemoGrid(store: store, demos: [("Shell Ejection", EventSchedule.shellEjection)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .wormhole:
            Section {
                FrequencyRow(title: "Wormhole events", value: $store.config.wormholeEvents)
                DemoGrid(store: store, demos: [("Infall", EventSchedule.infall),
                                               ("Emergence", EventSchedule.emergence),
                                               ("Rim Flare", EventSchedule.throatFlare),
                                               ("Far-Side Supernova", EventSchedule.farSupernova)])
            } header: {
                GroupHeader(title: "Events")
            }
        default:
            EmptyView()
        }
    }

    private func frameStar(zoom: Double, x: Double, top: Double) {
        store.config.starZoom = zoom
        store.config.starCenterX = x
        store.config.starLimbY = top
    }
}
