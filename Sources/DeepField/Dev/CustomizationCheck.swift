import Foundation

/// `--check-customization`: checks per-scene reset, tilt and image settings on plain
/// configs, without touching the saved settings.
enum CustomizationCheck {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        let d = WallpaperConfig()
        for kind in SceneKind.allCases { expect(!d.isCustomized(kind), "defaults read as customized: \(kind)") }

        // reset touches only the scene's own settings
        var c = d
        c.gasWind = 3; c.gasZone = RGB(1, 0, 0); c.ringedWind = 2; c.starDensity = 2; c.pulsars = false
        c.palette.receding = RGB(0, 1, 0); c.palette.galaxyCore = RGB(0, 0, 1)
        expect(c.isCustomized(.gasGiant), "gas giant not customized")
        expect(!c.isCustomized(.pulsar), "the sky's blinking stars counted as the pulsar's")
        let gas = c.resettingScene(.gasGiant)
        expect(gas.gasWind == d.gasWind && gas.gasZone == d.gasZone, "gas giant not reset")
        expect(gas.ringedWind == 2 && gas.starDensity == 2 && !gas.pulsars, "gas giant reset touched other settings")
        let bh = c.resettingScene(.blackHole)
        expect(bh.palette.receding == d.palette.receding, "black hole colors not reset")
        expect(bh.palette.galaxyCore == RGB(0, 0, 1), "black hole reset touched the galaxy's colors")

        failures += TiltCheck.failures()
        failures += PhoneGalleryCheck.failures()

        // per-scene image settings follow their scene
        var i = d
        i.scene = .comet
        i.sceneHasOwnImage = true
        i.bloom = 2; i.pixelSize = 6
        i.scene = .eclipse
        expect(i.bloom == d.bloom && i.pixelSize == d.pixelSize, "eclipse didn't get the shared image settings")
        i.contrast = 1.5                                   // shared change
        i.scene = .comet
        expect(i.bloom == 2 && i.pixelSize == 6 && i.contrast == d.contrast, "comet lost its own image settings")
        i.scene = .quasar
        expect(i.contrast == 1.5, "shared image change lost")
        i.scene = .comet
        i.sceneHasOwnImage = false
        expect(i.bloom == d.bloom && i.contrast == 1.5 && i.sharedImage == nil, "turning own image off didn't restore shared")

        // and survive a save and load
        var s = d
        s.scene = .gasGiant
        s.sceneHasOwnImage = true
        s.vignette = 0.7
        s.scene = .blackHole
        let back = (try? JSONEncoder().encode(s)).flatMap(WallpaperConfig.decode)
        expect(back == s, "per-scene image settings didn't round trip")
        var b = back ?? d
        b.scene = .gasGiant
        expect(b.vignette == 0.7, "gas giant's own vignette lost after a round trip")

        // damaged per-scene and shared image settings are clamped on load, before a switch uses them
        let damaged = #"{"sceneImage": {"wormhole": {"pixelSize": 0, "levels": 0}}, "sharedImage": {"pixelSize": 0}}"#
        var w = WallpaperConfig.decode(Data(damaged.utf8)) ?? d
        expect(w.sharedImage?.pixelSize == 1, "shared image settings not clamped")
        w.scene = .wormhole
        expect(w.pixelSize == 1 && w.levels == 2, "a scene's own image settings not clamped")

        // coordinates are kept in range: latitude stops at the poles, longitude goes around
        for (x, kept) in [(-91.0, -90.0), (-90, -90), (40.5, 40.5), (90, 90), (1000, 90)] {
            expect(WallpaperConfig.keptLatitude(x) == kept, "latitude \(x) wasn't kept as \(kept)")
        }
        for (x, kept) in [(200.0, -160.0), (-200, 160), (200.5, -159.5), (180, 180), (-180, -180), (360, 0), (-725, -5), (-120.25, -120.25)] {
            expect(WallpaperConfig.keptLongitude(x) == kept, "longitude \(x) wasn't kept as \(kept)")
            expect(WallpaperConfig.decode(Data("{\"homeLongitude\": \(x)}".utf8))?.homeLongitude == kept, "longitude \(x) loaded wrong")
        }
        expect(WallpaperConfig.keptLongitude(-360).sign == .plus, "longitude -360 reads -0")
        var unplaced = d
        unplaced.homeLatitude = .nan; unplaced.homeLongitude = .infinity
        expect(unplaced.sanitized() == d, "a place that isn't a number wasn't reset")
        let placing = try? ConfigKeys.apply([.init(key: "homeLatitude", raw: "95"), .init(key: "homeLongitude", raw: "200")], to: d)
        expect(placing?.config.homeLatitude == 90 && placing?.config.homeLongitude == -160 && placing?.warnings.count == 2, "the command line's place")

        // presets carry Live Earth's place only when asked, and files never follow the Mac
        var here = d, there = d
        here.homeLatitude = 10; here.homeFromDevice = true
        there.homeLatitude = 50; there.homeLongitude = 60; there.gasWind = 3
        let preset = UserPreset(name: "", config: there)
        expect(preset.applied(over: here) == there.withPlace(of: here), "a preset moved Live Earth's place")
        let file = PresetStore.fileData(for: preset).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let read = file.flatMap(PresetStore.preset(from:))?.config
        expect(read == there.withPlace(of: d), "a preset file carried Live Earth's place")

        let placed = UserPreset(name: "", config: there, includesPlace: true)
        expect(placed.applied(over: here) == there, "a preset that includes its place didn't apply it")
        var followed = there
        followed.homeFromDevice = true
        let placedFile = PresetStore.fileData(for: UserPreset(name: "", config: followed), includePlace: true)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap(PresetStore.preset(from:))
        expect(placedFile?.config == there && placedFile?.includesPlace == true, "a preset file lost its place")
        let saved = (try? JSONEncoder().encode(UserPreset(name: "p", config: followed, includesPlace: true)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap(PresetStore.preset(from:))
        expect(saved?.config == followed && saved?.includesPlace == true, "a saved preset lost its place")

        // a preset still shows as current after a scene's own image settings were edited and other
        // scenes visited, while a real difference in them still counts
        var edited = d
        edited.scene = .comet
        edited.sceneHasOwnImage = true
        edited.bloom = 2
        let current = UserPreset(name: "", config: edited)
        var visited = edited
        visited.scene = .eclipse
        visited.scene = .comet
        expect(current.matches(visited), "a preset stopped showing as current after visiting another scene")
        visited.bloom = 1
        visited.scene = .eclipse
        visited.scene = .comet
        visited.bloom = 2
        expect(current.matches(visited), "a preset stopped showing as current after an edit was undone")
        visited.bloom = 1
        expect(!current.matches(visited), "a preset showed as current with different own image settings")
        var away = edited
        away.scene = .eclipse
        visited.scene = .eclipse
        expect(!UserPreset(name: "", config: away).matches(visited), "a preset showed as current with another scene's own image settings different")

        // the welcome guide's tweaks undo to what was set before, in the scene's own image settings
        var base = d
        base.pixelSize = 2; base.bloom = 0.6; base.supernovae = .rare
        base.scene = .comet
        base.sceneHasOwnImage = true
        base.bloom = 0.1
        base.scene = .blackHole
        for scene in [SceneKind.blackHole, .comet] {
            var start = base
            start.scene = scene
            expect(Tweak.undoingAll(start, to: base) == start, "Undo All changed settings nothing had tweaked")
            for tweak in Tweak.all {
                var t = start
                tweak.apply(&t)
                tweak.turnOff(&t, base: base)
                expect(t == start, "\(tweak.id) didn't undo to the earlier settings")
            }
            var all = start
            Tweak.all.forEach { $0.apply(&all) }
            expect(Tweak.undoingAll(all, to: base) == start, "Undo All didn't restore the earlier settings")
        }
        var bright = d
        bright.bloom = 1.5
        var off = bright
        Tweak.all.first { $0.id == "glow" }?.turnOff(&off, base: bright)
        expect(off.bloom == d.bloom, "a tweak already on at the start couldn't be turned off")

        // a scene that draws the real sky leaves out Busier sky; Undo All there still undoes it, and
        // another scene shows whether it's on
        for scene in SceneKind.allCases {
            let hidden = Set(Tweak.all.map(\.id)).subtracting(Tweak.offered(in: scene).map(\.id))
            expect(hidden == (scene.drawsRealSky ? ["busy"] : []), "tweaks left out in \(scene): \(hidden.sorted())")
        }
        if let busy = Tweak.all.first(where: { $0.id == "busy" }) {
            var sky = base
            busy.apply(&sky)
            sky.scene = .liveEarth
            var undone = Tweak.undoingAll(sky, to: base)
            expect(undone != sky, "Undo All had nothing to undo in Live Earth")
            sky.scene = base.scene
            undone.scene = base.scene
            expect(busy.isOn(sky) && undone == base, "Busier sky was stuck after Live Earth")
        }

        // only the shared sky events are refused, and only where the real sky is drawn
        for scene in SceneKind.allCases {
            let refused = EventSchedule.named.filter { EventSchedule.realSkyReason($0, in: scene) != nil }.map(\.name)
            expect(refused == (scene.drawsRealSky ? ["supernova", "comet"] : []), "events refused in \(scene): \(refused)")
        }

        // Reset Framing keeps a hidden Subject height, and has nothing to do for it alone
        let framed = PhoneFraming(zoom: 1.5, shift: 0.2), shifted = PhoneFraming(shift: 0.2)
        expect(framed.reset(in: .liveEarth) == shifted && shifted.reset(in: .liveEarth) == shifted, "Reset Framing changed a hidden Subject height")
        expect(framed.reset(in: .gasGiant) == PhoneFraming(), "Reset Framing left something set")

        // the frame rates offered: the usual ones, each display's and the saved one, once each, in order
        func rates(_ displays: [Int], _ saved: Int = 24) -> [Int] { FrameRate.choices(displays: displays, current: saved) }
        expect(rates([60]) == [12, 24, 30, 60], "rates on a 60 Hz display")
        expect(rates([120]) == [12, 24, 30, 60, 120], "rates on a 120 Hz display")
        expect(rates([165]) == [12, 24, 30, 60, 165], "rates on a 165 Hz display")
        expect(rates([165, 60, 120, 165]) == [12, 24, 30, 60, 120, 165], "rates on mixed displays")
        expect(rates([60], 20) == [12, 20, 24, 30, 60], "a saved 20 fps isn't listed")
        expect(rates([60], 165) == [12, 24, 30, 60, 165], "a saved 165 fps isn't listed without its display")
        expect(rates([0]) == [12, 24, 30, 60] && rates([]) == [12, 24, 30, 60], "rates with no known display")

        // and saved rates hold up to the limit
        for (saved, loaded) in [(20, 20), (165, 165), (600, 600), (0, 1), (5000, FrameRate.limit)] {
            expect(WallpaperConfig.decode(Data("{\"fps\": \(saved)}".utf8))?.fps == loaded, "a saved \(saved) fps loaded wrong")
        }
        expect((try? ConfigKeys.apply([.init(key: "fps", raw: "165")], to: d))?.config.fps == 165, "the command line can't set 165 fps")

        // frames drawn in a second when the display link ticks at `hz` with some jitter
        func drawn(_ fps: Double, hz: Double) -> Int {
            var last = -1.0, n = 0
            for i in 0..<Int(hz) {
                let now = (Double(i) + (i % 2 == 0 ? 0.05 : -0.05)) / hz
                if FrameRate.isDue(after: now - last, fps: fps) { last = now; n += 1 }
            }
            return n
        }
        for (fps, hz, n) in [(24.0, 24.0, 24), (30, 30, 30), (60, 60, 60), (120, 120, 120), (165, 165, 165),
                             (165, 60, 60), (60, 165, 55), (24, 120, 30), (24, 165, 28)] {
            expect(drawn(fps, hz: hz) == n, "\(fps) fps on \(hz) Hz ticks drew \(drawn(fps, hz: hz))")
        }

        failures += SkyCoverCheck.failures()

        // a pixel size the picker doesn't list is added to it
        expect(WallpaperConfig.pixelSizes.including(5) == [1, 2, 3, 4, 5, 6, 8], "a 5 px pixel size isn't listed")
        expect(WallpaperConfig.pixelSizes.including(3) == WallpaperConfig.pixelSizes, "a listed pixel size was repeated")

        // a thumbnail is due again exactly when a setting its scene draws with changes
        let noon = Date(timeIntervalSince1970: 1_790_000_000), listed = Set(SceneKind.listed)
        func due(_ from: WallpaperConfig, _ to: WallpaperConfig, after seconds: Double = 0) -> Set<SceneKind> {
            let a = from.stillSettings(SceneKind.listed, at: noon)
            let b = to.stillSettings(SceneKind.listed, at: noon + seconds)
            return listed.filter { a[$0] == nil || a[$0] != b[$0] }
        }
        func expectDue(_ scenes: Set<SceneKind>, _ what: String, from: WallpaperConfig = d, _ change: (inout WallpaperConfig) -> Void) {
            var to = from
            change(&to)
            let got = due(from, to)
            expect(got == scenes, "thumbnails due after \(what): \(got.map(\.rawValue).sorted())")
        }
        let disks: Set<SceneKind> = [.blackHole, .tidalDisruption], planets: Set<SceneKind> = [.blackHole, .wormhole, .binary, .trinary]
        expectDue([], "no change") { _ in }
        expectDue([.gasGiant], "gas giant wind") { $0.gasWind = 3 }
        expectDue([.comet], "comet color") { $0.cometIonColor = RGB(1, 0, 0) }
        expectDue([.galaxy], "galaxy arms color") { $0.palette.galaxyArms = RGB(1, 0, 0) }
        expectDue(disks, "disk color") { $0.palette.receding = RGB(0, 1, 0) }
        expectDue(disks, "disk speed") { $0.diskSpeed = 2 }
        expectDue(disks.union([.wormhole]), "photon ring") { $0.photonRing = 2 }
        expectDue(planets, "planet count") { $0.planetCount = 1 }
        expectDue([.blackHole], "tilt") { $0.tilt = 20 }
        expectDue(listed.subtracting([.liveEarth]), "star density") { $0.starDensity = 2 }
        expectDue(listed.subtracting([.liveEarth]), "nebula color") { $0.palette.nebulaA = RGB(1, 0, 0) }
        expectDue([.liveEarth], "Live Earth's place") { $0.homeLatitude = 10 }
        expectDue([.liveEarth], "Live Earth's time") { $0.earthFreezeTime = true; $0.earthFrozenTime += 60 }
        expect(due(d, d, after: 0.25) == [.liveEarth], "only Live Earth shows the time")
        expectDue([], "settings no still shows") {
            $0.fps = 60; $0.pixelSize = 6; $0.lockScreenStill = true; $0.lockScreenSmooth = true; $0.homeFromDevice = true
            $0.supernovae = .rare; $0.comets = .rare; $0.wormholeEvents = .rare; $0.scene = .eclipse
        }
        var ownImage = d
        ownImage.scene = .comet
        ownImage.sceneHasOwnImage = true
        expectDue([], "giving a scene its own image settings", from: d) { $0.scene = .comet; $0.sceneHasOwnImage = true }
        expectDue([.comet], "a scene's own contrast", from: ownImage) { $0.contrast = 1.5 }
        expectDue([.comet], "a scene's own contrast, and leaving it", from: ownImage) { $0.contrast = 1.5; $0.scene = .eclipse }
        expectDue(listed.subtracting([.comet]), "the shared contrast", from: ownImage) { $0.scene = .eclipse; $0.contrast = 1.5 }

        for f in failures { print("FAIL:", f) }
        print(failures.isEmpty ? "customization OK" : "\(failures.count) failures")
        return failures.isEmpty
    }
}
