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

        for f in failures { print("FAIL:", f) }
        print(failures.isEmpty ? "customization OK" : "\(failures.count) failures")
        return failures.isEmpty
    }
}
