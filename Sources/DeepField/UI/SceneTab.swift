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
        case .binary, .trinary, .stellarSurface, .dysonSwarm: "Star colors follow the star type."
        case .pulsar: "Slowed down from hundreds of turns a second so the beams don't strobe."
        case .blackHoleMerger:
            if let d = BlackHoleDetection.all.first(where: { $0.matches(store.config) }) {
                "\(d.name): \(mass(d.m1)) and \(mass(d.m2)) solar masses made one of \(mass(d.remnant)). \(d.note)"
            } else {
                "Real mergers take seconds (stellar) to years (supermassive); every size is paced to the cycle here."
            }
        case .galaxy: store.config.darkMatter
            ? "Outer stars orbit as fast as inner ones, as observed in real galaxies."
            : "Without dark matter the outer disk lags behind. Real galaxies don't do this."
        default: nil
        }
    }

    private func mass(_ m: Double) -> String { m < 10 ? String(format: "%.1f", m) : String(format: "%.0f", m) }

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
                case .ringedPlanet:
                    SliderRow(title: "Size", value: $store.config.ringedSize, range: 0.7...1.3)
                    SliderRow(title: "Bands", value: $store.config.ringedBands, range: 0.5...2)
                        .help("Lower for a few broad belts, higher for many fine ones")
                    SliderRow(title: "Turbulence", value: $store.config.ringedTurbulence, range: 0...2.5)
                        .help("How much the bands swirl and streak where they meet")
                    SliderRow(title: "Wind", value: $store.config.ringedWind, range: 0...3)
                        .help("How fast the bands drift and shear past each other")
                case .auroraOrbit:
                    SliderRow(title: "Brightness", value: $store.config.auroraBrightness, range: 0...2.5)
                    SliderRow(title: "Speed", value: $store.config.auroraActivity, range: 0.05...4)
                        .help("How fast the curtains ripple, fold and drift")
                    SliderRow(title: "Distance", value: $store.config.auroraDistance, range: 22...60) { String(format: "%.0f°", $0) }
                        .help("How far ahead the magnetic pole lies. Nearer brings the curtains in below you; farther puts them along the horizon")
                    SliderRow(title: "Oval size", value: $store.config.auroraOvalSize, range: 10...30) { String(format: "%.0f°", $0) }
                case .liveEarth:
                    SliderRow(title: "Distance", value: $store.config.earthDistance, range: 1.4...12) {
                        let km = ($0 - 1) * 6371
                        return km >= 10_000 ? String(format: "%.0fk km", km / 1000) : String(format: "%.0f km", km)
                    }
                    .help("Height above the chosen place. Geostationary satellites orbit at about 35,800 km")
                    SliderRow(title: "Horizontal position", value: $store.config.earthCenterX, range: -1...1)
                    SliderRow(title: "Vertical position", value: $store.config.earthCenterY, range: -1...1)
                    SliderRow(title: "Atmosphere", value: $store.config.earthAtmosphere, range: 0...2)
                    SliderRow(title: "Moon size", value: $store.config.earthMoonSize, range: 1...6) { String(format: "%.1fx", $0) }
                        .help("1x is its true size. The Moon only shows when it's behind Earth from here")
                    SliderRow(title: "Stars", value: $store.config.earthStars, range: 0...3)
                        .help("The real stars, where they are in the sky at the moment shown")
                    SliderRow(title: "Milky Way", value: $store.config.earthMilkyWay, range: 0...3)
                    Toggle("Planets", isOn: $store.config.earthPlanets)
                        .help("Mercury to Neptune where they really are, at their real brightness")
                    if store.config.earthPlanets {
                        SliderRow(title: "Planet size", value: $store.config.earthPlanetSize, range: 1...300) {
                            $0 < 1.5 ? "true" : String(format: "%.0fx", $0)
                        }
                        .help("At true size they're points of light, as you'd see them. Larger shows their disks, phases, bands and Saturn's rings")
                        Toggle("Label planets", isOn: $store.config.earthPlanetLabels)
                    }
                    Toggle("Hide the sun at night", isOn: $store.config.earthHideSunAtNight)
                        .help("While it's night at the chosen place the sun sits behind Earth; this hides its disk and glare but keeps its light")
                    Toggle("Mark the place", isOn: $store.config.earthMarker)
                case .gasGiant:
                    SliderRow(title: "Wind", value: $store.config.gasWind, range: 0...4)
                        .help("How fast the bands flow and the storms spin")
                    SliderRow(title: "Turbulence", value: $store.config.gasTurbulence, range: 0...2.5)
                    SliderRow(title: "Storm size", value: $store.config.gasStormSize, range: 0.5...2)
                    SliderRow(title: "Distance", value: $store.config.gasDistance, range: 1.2...3)
                        .help("How close you are, in planet radii from its center")
                    SliderRow(title: "Sun angle", value: $store.config.gasSun, range: 0...140) { String(format: "%.0f°", $0) }
                    SliderRow(title: "Axis tilt", value: $store.config.gasTilt, range: -40...40) { String(format: "%.0f°", $0) }
                    Toggle("Moon", isOn: $store.config.gasMoon)
                    FrequencyRow(title: "Lightning", value: $store.config.gasLightning)
                case .protoplanetaryDisk:
                    Picker("Look", selection: $store.config.protoLook) {
                        ForEach(ProtoDiskLook.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Scattered light shows the disk's surface lit by the star; the ALMA glow shows the dust's own warmth at millimeter wavelengths, rings and gaps seen right through")
                    SliderRow(title: "Viewing angle", value: $store.config.protoView, range: 0...88) { String(format: "%.0f°", $0) }
                        .help("0° looks straight down on the disk; near 90° it's edge-on, a dark dust lane between two lit surfaces")
                    SliderRow(title: "Slant", value: $store.config.protoSlant, range: -60...60) { String(format: "%.0f°", $0) }
                    SliderRow(title: "Size", value: $store.config.protoSize, range: 0.6...1.4)
                    Stepper("Gaps: \(store.config.protoGaps)", value: $store.config.protoGaps, in: 1...7)
                        .help("Each gap is cleared by a forming planet orbiting inside it")
                    SliderRow(title: "Gap width", value: $store.config.protoGapWidth, range: 0.4...2)
                    SliderRow(title: "Flaring", value: $store.config.protoFlaring, range: 0...2)
                        .help("How fast the disk thickens outward. More flaring catches more starlight on its surface")
                    SliderRow(title: "Orbit speed", value: $store.config.protoOrbitSpeed, range: 0...4)
                    Toggle("Jets", isOn: $store.config.protoJets)
                        .help("Thin jets from the star's poles, with knots of shocked gas moving outward")
                case .neutronMerger:
                    SliderRow(title: "Cycle length", value: $store.config.mergerCycleMinutes, range: 2...15) { String(format: "%.1f min", $0) }
                        .help("From one merger to the next: the kilonova fades around the new remnant, a companion falls in and is captured, and their orbit speeds up until they merge")
                    SliderRow(title: "Star brightness", value: $store.config.mergerBrightness, range: 0.3...2.5)
                    SliderRow(title: "Glow", value: $store.config.mergerGlow, range: 0.4...2.5)
                        .help("How far each star's halo spreads")
                    SliderRow(title: "Wave ripple", value: $store.config.mergerWaves, range: 0...3)
                        .help("How strongly the gravitational waves bend the starlight behind them")
                    SliderRow(title: "Viewing angle", value: $store.config.mergerView, range: 0...85) { String(format: "%.0f°", $0) }
                        .help("0° looks straight down onto the orbit")
                    Toggle("Jet", isOn: $store.config.mergerJet)
                        .help("A short jet punching out along the orbit's axis just after the merger")
                case .blackHoleMerger:
                    Picker("Detection", selection: bbhDetection) {
                        ForEach(BlackHoleDetection.all, id: \.name) { Text($0.name).tag($0.name) }
                        // listed only while current: it has nothing to apply, so choosing it would snap back
                        if bbhDetection.wrappedValue == "Custom" { Text("Custom").tag("Custom") }
                    }
                    .help("Load the masses, spins and viewing angle of a merger LIGO, Virgo and KAGRA heard")
                    Picker("Black holes", selection: $store.config.bbhModel) {
                        ForEach(BlackHoleMergerModel.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Stellar pairs merge in empty space, or in a quasar's gas disk where the kicked remnant sets off a flare. Intermediate ones sit in a dense star cluster. Supermassive ones, brought together by colliding galaxies, clear a hole in their gas disk and feed on streams from its edge")
                    SliderRow(title: "Mass ratio", value: $store.config.bbhMassRatio, range: 0.05...1)
                        .help("The lighter hole's mass over the heavier one's. Unequal pairs are tighter, wind through more orbits and add a third arm to the waves")
                    SliderRow(title: "Remnant spin", value: $store.config.bbhSpin, range: 0...0.98)
                        .help("Faster spin flattens one side of the shadow and makes the ringdown higher and longer")
                    SliderRow(title: "Precession", value: $store.config.bbhPrecession, range: 0...1)
                        .help("Spins tilted off the orbit's axis make the orbit wobble, faster as it tightens. They also make the recoil kick much stronger")
                    SliderRow(title: "Recoil kick", value: $store.config.bbhKick, range: 0...2)
                        .help("Waves beamed unevenly push the remnant away. Unequal masses and tilted spins kick hardest")
                    Toggle("Eccentric orbit", isOn: $store.config.bbhEccentric)
                        .help("The pair stays eccentric to the end: the companion dives in, whirls round and swings back out, sending a burst of waves at each close pass")
                    Toggle("Hierarchical chain", isOn: $store.config.bbhChain)
                        .help("Each remnant becomes the heavy partner of the next merger, three times over, so it grows and each new companion is relatively smaller")
                    SliderRow(title: "Speed", value: $store.config.bbhSpeed, range: 0.25...3) { String(format: "%.2fx", $0) }
                        .help("How fast everything in this scene moves, the merger cycle included")
                    SliderRow(title: "Cycle length", value: $store.config.bbhCycleMinutes, range: 2...15) { String(format: "%.1f min", $0) }
                        .help("From one merger to the next: the remnant settles, a companion falls in and is captured, and their orbit speeds up until they merge, timed at Speed 1")
                    SliderRow(title: "Ringdown slow motion", value: $store.config.bbhRingdown, range: 1...6) { String(format: "%.1fx", $0) }
                        .help("Slows the last second of the chirp and the ringdown so the joined shadow's spin and wobble can be seen. 1 is true to the rest of the scene")
                    SliderRow(title: "Lensing", value: $store.config.bbhLensing, range: 0...2)
                        .help("How strongly each hole bends the light behind it into arcs and rings")
                    Toggle("Background galaxy", isOn: $store.config.bbhGalaxy)
                        .help("A distant galaxy almost straight behind the pair, bent into a ring that breaks into arcs as they move")
                    Toggle("Strain trace", isOn: $store.config.bbhTrace)
                        .help("The waves as a detector records them, drawn along the bottom: a rising chirp, the merger, the ringdown")
                    SliderRow(title: "Wave ripple", value: $store.config.bbhWaves, range: 0...3)
                        .help("How strongly the gravitational waves bend the starlight behind them")
                    SliderRow(title: "Viewing angle", value: $store.config.bbhView, range: 0...85) { String(format: "%.0f°", $0) }
                        .help("0° looks straight down onto the orbit")
                case .dysonSwarm:
                    StarPicker(title: "Star", star: $store.config.dysonStar)
                    SliderRow(title: "Density", value: $store.config.dysonDensity, range: 0...1)
                        .help("From a few sparse bands of panels to a swarm that nearly closes over the star")
                    Stepper("Rings: \(store.config.dysonRings)", value: $store.config.dysonRings, in: 3...20)
                    SliderRow(title: "Orbit speed", value: $store.config.dysonOrbitSpeed, range: 0...4)
                    SliderRow(title: "Panel glints", value: $store.config.dysonGlint, range: 0...2.5)
                        .help("How brightly panels flash as their mirrors swing through the line between the star and you")
                case .roguePlanet:
                    SliderRow(title: "Size", value: $store.config.rogueSize, range: 0.5...1.8)
                    SliderRow(title: "Position X", value: $store.config.rogueCenterX, range: -0.8...0.8)
                    SliderRow(title: "Position Y", value: $store.config.rogueCenterY, range: -0.8...0.8)
                    SliderRow(title: "Spin", value: $store.config.rogueSpin, range: 0...3)
                        .help("How fast the planet turns")
                    SliderRow(title: "Aurora", value: $store.config.rogueAurora, range: 0...2.5)
                        .help("The glow round both magnetic poles, powered by the planet's own magnetic field")
                    SliderRow(title: "Rift glow", value: $store.config.rogueRift, range: 0...2.5)
                        .help("Heat from inside the planet glowing through cracks in its ice")
                    SliderRow(title: "Milky Way", value: $store.config.rogueMilkyWay, range: 0...2)
                    Toggle("Moon", isOn: $store.config.rogueMoon)
                case .eclipse:
                    Picker("Motion", selection: $store.config.eclipseMotion) {
                        ForEach(EclipseMotion.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Hold at totality parks the moon over the sun, so the corona, prominences and eruptions are always out")
                    if store.config.eclipseMotion == .cycle {
                        SliderRow(title: "Cycle length", value: $store.config.eclipseCycleMinutes, range: 1...10) { String(format: "%.1f min", $0) }
                            .help("How long one eclipse takes, from full sun through totality and back to full sun")
                    }
                    SliderRow(title: "Corona size", value: $store.config.eclipseCoronaSize, range: 0.5...2)
                    SliderRow(title: "Corona brightness", value: $store.config.eclipseCoronaBrightness, range: 0.3...2.5)
                    SliderRow(title: "Prominences", value: $store.config.eclipseProminences, range: 0...2.5)
                        .help("How many pink loops and sheets of cool gas stand round the edge of the sun, and how often small jets shoot up")
                case .comet:
                    SliderRow(title: "Tail length", value: $store.config.cometTailLength, range: 0.3...2)
                    SliderRow(title: "Activity", value: $store.config.cometActivity, range: 0.2...2.5)
                case .stellarSurface:
                    StarPicker(title: "Star", star: $store.config.closeStar)
                    SliderRow(title: "Sunspots", value: $store.config.starSpots, range: 0...1.5)
                    SliderRow(title: "Rotation", value: $store.config.starRotation, range: 0...4)
                case .quasar:
                    SliderRow(title: "Jet length", value: $store.config.quasarJetLength, range: 0.5...1.3)
                    SliderRow(title: "Jet brightness", value: $store.config.quasarJetBrightness, range: 0.2...2.5)
                    SliderRow(title: "Jet direction", value: $store.config.quasarJetAngle, range: -60...60) { String(format: "%.0f°", $0) }
                        .help("Which way the jets point across the screen")
                    SliderRow(title: "Knot speed", value: $store.config.quasarKnotSpeed, range: 0...3)
                        .help("How fast the bright knots travel out along the jets")
                    SliderRow(title: "Galaxy", value: $store.config.quasarGalaxy, range: 0...2)
                        .help("The host galaxy's brightness. All the way down hides it, leaving the nucleus and jets")
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
                    HStack(alignment: .firstTextBaseline) {
                        Text(scene.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        Spacer()
                        Button("Reset") { store.config = store.config.resettingScene(scene) }
                            .controlSize(.small)
                            .disabled(!store.config.isCustomized(scene))
                            .help("Puts this scene's settings and colors back to their defaults" + (scene.sharedNote.map { ". \($0)" } ?? ""))
                    }
                    Text(scene.blurb).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textCase(nil)
                .padding(.bottom, 4)
                .help(scene.details ?? "")
            } footer: {
                if let note { GroupFooter(note) }
            }
            if scene == .ringedPlanet { ringedSections }
            if scene == .auroraOrbit { auroraSections }
            if scene == .liveEarth { LiveEarthSections(store: store) }
            if scene == .eclipse { eclipseSections }
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
            // its camera only goes where its own place and distance put it
            if !scene.drawsRealSky {
                Section {
                    if !cameraCollapsed { camera }
                } header: {
                    CollapsibleHeader(title: "Camera", collapsed: $cameraCollapsed)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var camera: some View {
        switch scene {
        case .galaxy:
            SliderRow(title: "Viewing angle", value: $store.config.galaxyView, range: 5...85) { String(format: "%.0f°", $0) }
        case .quasar:
            SliderRow(title: "Viewing angle", value: $store.config.quasarView, range: 20...90) { String(format: "%.0f°", $0) }
                .help("The angle between the jets and our line of sight. Smaller angles boost the approaching jet and hide the receding one; near 90° the dust ring hides the core")
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
        case .gasGiant:
            Section {
                FrequencyRow(title: "Comet impacts", value: $store.config.gasEvents)
                DemoGrid(store: store, demos: [("Comet Impact", EventSchedule.cometImpact)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .protoplanetaryDisk:
            Section {
                FrequencyRow(title: "Accretion outbursts", value: $store.config.protoEvents)
                DemoGrid(store: store, demos: [("Outburst", EventSchedule.accretionOutburst)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .blackHoleMerger:
            Section {
                DemoGrid(store: store, demos: [("Merger", EventSchedule.blackHoleMerger)])
            } header: {
                GroupHeader(title: "Events")
            } footer: {
                GroupFooter("The merger ends every cycle; set how often with Cycle length.")
            }
        case .neutronMerger:
            Section {
                DemoGrid(store: store, demos: [("Merger", EventSchedule.neutronMerger)])
            } header: {
                GroupHeader(title: "Events")
            } footer: {
                GroupFooter("The merger ends every cycle; set how often with Cycle length.")
            }
        case .dysonSwarm:
            Section {
                FrequencyRow(title: "Reorientation waves", value: $store.config.dysonEvents)
                DemoGrid(store: store, demos: [("Reorientation Wave", EventSchedule.swarmWave)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .roguePlanet:
            Section {
                FrequencyRow(title: "Star glints", value: $store.config.rogueEvents)
                    .help("A bright star passing behind the planet, its light bent round the limb by the thin atmosphere")
                DemoGrid(store: store, demos: [("Star Glint", EventSchedule.starGlint)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .eclipse:
            Section {
                FrequencyRow(title: "Eruptions", value: $store.config.eclipseEvents)
                DemoGrid(store: store, demos: [("Eruption", EventSchedule.eclipseEruption)])
            } header: {
                GroupHeader(title: "Events")
            } footer: {
                GroupFooter(store.config.eclipseMotion == .cycle
                            ? "Eruptions wait for totality, when the corona is out."
                            : "Held at totality, eruptions come every few minutes, with small jets in between.")
            }
        case .auroraOrbit:
            Section {
                FrequencyRow(title: "Substorms", value: $store.config.auroraEvents)
                DemoGrid(store: store, demos: [("Substorm", EventSchedule.substorm)])
            } header: {
                GroupHeader(title: "Events")
            }
        case .ringedPlanet:
            Section {
                FrequencyRow(title: "Great white storms", value: $store.config.ringedEvents)
                DemoGrid(store: store, demos: [("White Storm", EventSchedule.whiteStorm)])
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
        case .quasar:
            Section {
                FrequencyRow(title: "Flares", value: $store.config.quasarEvents)
                DemoGrid(store: store, demos: [("Flare", EventSchedule.quasarFlare)])
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

    /// The aurora scene's Earth and view groups.
    @ViewBuilder private var auroraSections: some View {
        Section {
            SliderRow(title: "City lights", value: $store.config.auroraCityLights, range: 0...2.5)
            SliderRow(title: "Clouds", value: $store.config.auroraClouds, range: 0...1.5)
            SliderRow(title: "Moonlight", value: $store.config.auroraMoonlight, range: 0...1.5)
                .help("Faint light on the clouds and seas")
            FrequencyRow(title: "Lightning", value: $store.config.auroraLightning)
        } header: {
            GroupHeader(title: "Earth")
        }
        Section {
            SliderRow(title: "Altitude", value: $store.config.auroraAltitude, range: 250...1500) { String(format: "%.0f km", $0) }
            SliderRow(title: "Horizon", value: $store.config.auroraHorizon, range: -0.6...0.8)
                .help("Where the edge of Earth sits on screen")
            SliderRow(title: "Ground drift", value: $store.config.auroraDrift, range: 0...4)
                .help("The ground sliding by below as you orbit")
            SliderRow(title: "Sunrise", value: $store.config.auroraSunrise, range: 0...1.5)
                .help("Dawn glow along one end of the horizon")
        } header: {
            GroupHeader(title: "View")
        }
    }

    /// The eclipse scene's ground, sky body and air.
    @ViewBuilder private var eclipseSections: some View {
        Section {
            Toggle("Landscape", isOn: $store.config.eclipseLandscape)
            if store.config.eclipseLandscape {
                Picker("Surface", selection: $store.config.eclipseWorld) {
                    ForEach(EclipseWorld.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            GroupHeader(title: "Ground")
        }
        Section {
            Picker("Body", selection: $store.config.eclipseSkyBody) {
                ForEach(EclipseSkyBody.allCases) { Text($0.title).tag($0) }
            }
            if store.config.eclipseSkyBody != .none {
                SliderRow(title: "Size", value: $store.config.eclipsePlanetSize, range: 0.4...1.8)
                SliderRow(title: "Horizontal position", value: $store.config.eclipsePlanetX, range: -1...1)
                SliderRow(title: "Height", value: $store.config.eclipsePlanetY, range: -0.6...0.9)
            }
        } header: {
            GroupHeader(title: "In the sky")
        }
        Section {
            Toggle("Atmosphere", isOn: $store.config.eclipseAtmosphere)
                .help("Off is an airless world with a black sky. With air the sky darkens as the sun goes, and at totality a sunset glow rings the horizon")
            if store.config.eclipseAtmosphere {
                Picker("Composition", selection: airPreset) {
                    ForEach(EclipseAirPreset.all, id: \.name) { Text($0.name).tag($0.name) }
                    // listed only while current, as for Detection
                    if airPreset.wrappedValue == "Custom" { Text("Custom").tag("Custom") }
                }
                ColorRow("Sky color", store.color(\.eclipseAirColor))
                SliderRow(title: "Density", value: $store.config.eclipseAirDensity, range: 0.1...3)
                SliderRow(title: "Haze", value: $store.config.eclipseAirHaze, range: 0...2)
                    .help("Dust or smog: it whitens and dims the sky and spreads a glow round the sun")
                SliderRow(title: "Clouds", value: $store.config.eclipseClouds, range: 0...1)
            }
        } header: {
            GroupHeader(title: "Air")
        }
    }

    /// The black hole merger's detection, by name; editing anything after picking one makes it Custom.
    private var bbhDetection: Binding<String> {
        Binding(
            get: { BlackHoleDetection.all.first { $0.matches(store.config) }?.name ?? "Custom" },
            set: { name in BlackHoleDetection.all.first { $0.name == name }?.apply(to: &store.config) }
        )
    }

    /// The air composition, by preset name; editing anything after picking one makes it Custom.
    private var airPreset: Binding<String> {
        Binding(
            get: { EclipseAirPreset.all.first { $0.matches(store.config) }?.name ?? "Custom" },
            set: { name in EclipseAirPreset.all.first { $0.name == name }?.apply(to: &store.config) }
        )
    }

    /// The ringed planet's rings, lighting and moons, each in its own group.
    @ViewBuilder private var ringedSections: some View {
        Section {
            Picker("Style", selection: $store.config.ringedRingStyle) {
                ForEach(RingStyle.allCases) { Text($0.title).tag($0) }
            }
            if store.config.ringedRingStyle != .none {
                SliderRow(title: "Width", value: $store.config.ringedRingWidth, range: 0.6...1.6)
                SliderRow(title: "Density", value: $store.config.ringedRingDensity, range: 0.3...1.6)
                    .help("Lower for thin, see-through rings, higher for solid ones")
                if store.config.ringedRingStyle != .narrow {
                    Toggle("Spokes", isOn: $store.config.ringedSpokes)
                        .help("Faint wisps of dust over the dense ring, turning with the planet's magnetic field")
                }
            }
            SliderRow(title: "Opening", value: $store.config.ringedTilt, range: 2...40) { String(format: "%.0f°", $0) }
                .help("How far the ring plane is tipped toward you")
            SliderRow(title: "Slant", value: $store.config.ringedRoll, range: -40...40) { String(format: "%.0f°", $0) }
        } header: {
            GroupHeader(title: "Rings")
        }
        Section {
            SliderRow(title: "Sun angle", value: $store.config.ringedSun, range: 0...160) { String(format: "%.0f°", $0) }
                .help("0° lights the planet from behind you; past 90° it turns into a crescent and the rings glow, backlit")
            SliderRow(title: "Sun height", value: $store.config.ringedSunHeight, range: -25...40) { String(format: "%.0f°", $0) }
                .help("The sun above the ring plane. Below it, you see the rings' unlit side, glowing where they're thin, and their shadow falls across the planet")
        } header: {
            GroupHeader(title: "Lighting")
        }
        Section {
            Stepper("Moons: \(store.config.ringedMoonCount)", value: $store.config.ringedMoonCount, in: 0...3)
            if store.config.ringedMoonCount > 0 {
                SliderRow(title: "Moon size", value: $store.config.ringedMoonSize, range: 0.5...2)
                SliderRow(title: "Orbit speed", value: $store.config.ringedMoonSpeed, range: 0.2...4)
            }
        } header: {
            GroupHeader(title: "Moons")
        }
    }

    private func frameStar(zoom: Double, x: Double, top: Double) {
        store.config.starZoom = zoom
        store.config.starCenterX = x
        store.config.starLimbY = top
    }
}
