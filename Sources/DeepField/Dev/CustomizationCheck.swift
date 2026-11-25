import Foundation

/// `--check-customization`: checks per-scene reset and per-scene image settings on plain
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

        for f in failures { print("FAIL:", f) }
        print(failures.isEmpty ? "customization OK" : "\(failures.count) failures")
        return failures.isEmpty
    }
}
