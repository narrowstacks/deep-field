import SwiftUI

struct SceneTab: View {
    @ObservedObject var store: ConfigStore

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
                    Picker("Beams", selection: $store.config.pulsarBeams) {
                        ForEach(PulsarBeams.allCases) { Text($0.title).tag($0) }
                    }
                    if store.config.pulsarBeams != .none {
                        SliderRow(title: "Beam width", value: $store.config.pulsarBeamWidth, range: 2...20) { String(format: "%.0f°", $0) }
                        SliderRow(title: "Beam brightness", value: $store.config.pulsarBeamIntensity, range: 0.2...3)
                        SliderRow(title: "Beam trail", value: $store.config.pulsarBeamTrail, range: 0...3)
                        ColorPicker("Beam color", selection: store.color(\.pulsarBeamColor), supportsOpacity: false)
                    }
                    Toggle("Magnetic field", isOn: $store.config.pulsarFieldLines)
                    if store.config.pulsarFieldLines {
                        Picker("Field style", selection: $store.config.pulsarFieldStyle) {
                            ForEach(PulsarFieldStyle.allCases) { Text($0.title).tag($0) }
                        }
                        SliderRow(title: "Field brightness", value: $store.config.pulsarFieldIntensity, range: 0.2...3)
                        ColorPicker("Field color", selection: store.color(\.pulsarFieldColor), supportsOpacity: false)
                    }
                    Toggle("Dust ring", isOn: $store.config.pulsarRing)
                    if store.config.pulsarRing {
                        SliderRow(title: "Ring brightness", value: $store.config.pulsarRingIntensity, range: 0.2...3)
                        ColorPicker("Ring color", selection: store.color(\.pulsarRingColor), supportsOpacity: false)
                    }
                    Toggle("Wind nebula (torus and jets)", isOn: $store.config.pulsarNebula)
                    if store.config.pulsarNebula {
                        SliderRow(title: "Nebula brightness", value: $store.config.pulsarNebulaIntensity, range: 0.2...3)
                        ColorPicker("Nebula color", selection: store.color(\.pulsarNebulaColor), supportsOpacity: false)
                    }
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
                        ColorPicker("Hydrogen (Hα)", selection: store.color(\.nebulaHa), supportsOpacity: false)
                        ColorPicker("Oxygen (OIII)", selection: store.color(\.nebulaOIII), supportsOpacity: false)
                        ColorPicker("Sulfur (SII)", selection: store.color(\.nebulaSII), supportsOpacity: false)
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
                        ColorPicker("Ion tail", selection: store.color(\.cometIonColor), supportsOpacity: false)
                        ColorPicker("Dust tail", selection: store.color(\.cometDustColor), supportsOpacity: false)
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
                    FrequencyRow(title: "Flares and eruptions", value: $store.config.starFlares)
                    LabeledContent("Show me") {
                        VStack(alignment: .trailing) {
                            HStack {
                                Button("Flare") { store.demo(EventSchedule.stellarFlare) }
                                Button("Surge") { store.demo(EventSchedule.surge) }
                            }
                            HStack {
                                Button("Prominence eruption") { store.demo(EventSchedule.prominenceEruption) }
                                Button("Coronal mass ejection") { store.demo(EventSchedule.coronalEjection) }
                            }
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
