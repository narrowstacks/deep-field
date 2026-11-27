import Foundation

/// Part of `--check-customization`: each scene keeps its own tilt, through scene switches, saves
/// old and new, presets, resets and the command line.
enum TiltCheck {
    private static let all = SceneKind.allCases, tilted = all.filter(\.hasTilt)

    /// What `kind` shows, switched to on a copy as thumbnails and exports do.
    private static func shown(_ c: WallpaperConfig, _ kind: SceneKind) -> Double {
        var c = c
        c.scene = kind
        return c.cameraTilt
    }

    private static func shown(_ c: WallpaperConfig) -> [SceneKind: Double] {
        Dictionary(uniqueKeysWithValues: all.map { ($0, shown(c, $0)) })
    }

    /// `c` with every scene that has a tilt at its own, 2 degrees and up, and `scene` active.
    private static func distinct(_ c: WallpaperConfig, active: SceneKind) -> WallpaperConfig {
        var c = c
        for (i, kind) in tilted.enumerated() {
            c.scene = kind
            c.tilt = 2 + Double(i)
        }
        c.scene = active
        return c
    }

    private static func saved(_ c: WallpaperConfig) -> WallpaperConfig? {
        (try? JSONEncoder().encode(c)).flatMap(WallpaperConfig.decode)
    }

    private static func load(_ dict: [String: Any]) -> WallpaperConfig? {
        (try? JSONSerialization.data(withJSONObject: dict)).flatMap(WallpaperConfig.decode)
    }

    /// A save by a version with one shared tilt.
    static func oldSave(_ scene: SceneKind, tilt: Double) -> [String: Any] {
        var dict = ConfigKeys.object(WallpaperConfig())
        dict["sceneTilt"] = nil
        dict["sharedTilt"] = nil
        dict["scene"] = scene.rawValue
        dict["tilt"] = tilt
        return dict
    }

    static func failures() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        let d = WallpaperConfig()

        for kind in all {
            expect(kind.hasTilt == WallpaperConfig.sceneKeys(kind).contains("tilt"), "\(kind): the slider and the reset disagree about tilt")
        }

        // scenes without a tilt draw the same whatever is set, even set directly
        for kind in all where !kind.hasTilt {
            var c = d, t = d
            c.scene = kind
            t.scene = kind
            t.tilt = 20
            expect(t.bakeKey == c.bakeKey && Camera(t, aspect: 1.6).pos == Camera(c, aspect: 1.6).pos, "a tilt moved \(kind)")
        }

        // a tilt is its scene's only, and comes back with it by any order of visits
        for kind in tilted {
            for start in all {
                var c = distinct(d, active: start)
                let before = shown(c)
                c.scene = kind
                c.tilt = 24.5
                expect(shown(c) == before.merging([kind: 24.5]) { $1 }, "tilting \(kind) from \(start) changed another scene")
            }
        }
        for start in all {
            for c in [d, distinct(d, active: start)] {
                var v = c
                v.scene = start
                let home = v
                for kind in all + all.reversed() { v.scene = kind }
                v.scene = start
                expect(v == home, "visiting every scene and coming back to \(start) changed the settings")
            }
        }
        // setting a tilt back leaves nothing behind that makes equal settings unequal
        var there = d
        there.scene = .comet
        there.tilt = 20
        there.scene = .eclipse
        there.scene = .comet
        there.tilt = WallpaperConfig.defaultTilt
        there.scene = d.scene
        expect(there == d, "a tilt set and put back still reads as a change")

        // upgrade: one shared tilt becomes every scene's, whichever scene is active
        for active in all {
            for tilt in [WallpaperConfig.defaultTilt, 20, 1.0 / 3, 40] {
                guard let c = load(oldSave(active, tilt: tilt)) else { expect(false, "an old save didn't load"); continue }
                for kind in all {
                    var old = d      // what the older version drew
                    old.scene = kind
                    let want = kind.hasTilt ? tilt : old.cameraTilt
                    expect(shown(c, kind) == want, "old save on \(active) at \(tilt): \(kind) shows \(shown(c, kind))")
                }
                expect(c.scene == active && c.tilt == tilt, "old save on \(active) at \(tilt): an older version would lose it")
                var again = c
                for _ in 0..<3 {
                    again = saved(again) ?? d
                    expect(again == c, "old save on \(active) at \(tilt): saving and loading changed it")
                }
                // changing one scene afterwards leaves the rest at the old tilt
                again.scene = .comet
                again.tilt = 11
                again = saved(again) ?? d
                expect(tilted.allSatisfy { shown(again, $0) == ($0 == .comet ? 11 : tilt) }, "old save on \(active) at \(tilt): then tilting comet")
            }
        }
        let partial = WallpaperConfig.decode(Data(#"{"tilt": 20}"#.utf8)) ?? d
        expect(tilted.allSatisfy { shown(partial, $0) == 20 }, "a file with only a tilt")
        expect(WallpaperConfig.decode(Data("{}".utf8)) == d, "an empty save")

        // round trips, and an older version's view of a new save
        for active in all {
            let c = distinct(load(oldSave(.galaxy, tilt: 20)) ?? d, active: active)
            expect(saved(c) == c && saved(c).map(shown) == shown(c), "\(active): tilts didn't round trip")
            let dict = ConfigKeys.object(c)
            expect(dict["tilt"] as? Double == (active.hasTilt ? c.cameraTilt : 20), "\(active): an older version would show \(dict["tilt"] ?? "nothing")")
            // the older version saves what it knows, then this one loads it
            let back = load(oldSave(active, tilt: dict["tilt"] as? Double ?? 0)) ?? d
            expect(tilted.allSatisfy { shown(back, $0) == c.tilt }, "\(active): downgrading and upgrading again")
        }

        // damaged and hand-edited saves
        var stale = ConfigKeys.object(there)
        stale["sceneTilt"] = ["blackHole": 9, "quasar": 20, "eclipse": WallpaperConfig.defaultTilt]
        expect(load(stale) == d, "meaningless parked tilts made equal settings unequal")
        var bad = oldSave(.comet, tilt: 20)
        bad["sharedTilt"] = "high"
        bad["sceneTilt"] = 3
        expect(load(bad).map { c in tilted.allSatisfy { shown(c, $0) == 20 } } == true, "damaged tilts lost the one that loads")
        // a newer version's scene, which loads as the default scene with that scene's own tilt
        var newer = ConfigKeys.object(distinct(d, active: .comet))
        let cometTilt = newer["tilt"] as? Double, shownBefore = shown(distinct(d, active: .comet))
        newer["scene"] = "aNewerScene"
        var parked = newer["sceneTilt"] as? [String: Double] ?? [:]
        parked["comet"] = cometTilt
        newer["sceneTilt"] = parked
        newer["tilt"] = 24.5
        if let c = load(newer) {
            expect(shown(c) == shownBefore && c.sceneTilt["aNewerScene"] == 24.5, "a newer version's scene disturbed the tilts")
            expect(saved(c) == c, "a newer version's scene isn't stable")
        } else { expect(false, "a newer version's save didn't load") }

        // presets: exact, recognized again, and the same through a file; old ones as they were
        for active in all {
            let c = distinct(d, active: active), preset = UserPreset(name: "p", config: c)
            var now = d
            now.scene = .eclipse
            now.tilt = 17
            let applied = preset.applied(over: now)
            expect(applied == c && shown(applied) == shown(c), "\(active): a preset didn't apply its tilts")
            var visited = applied
            all.forEach { visited.scene = $0 }
            visited.scene = active
            expect(preset.applied(over: visited) == visited, "\(active): a preset isn't current after visiting other scenes")
            let file = PresetStore.fileData(for: preset).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            expect(file.flatMap(PresetStore.preset(from:))?.config == c, "\(active): a preset file lost tilts")

            let old = oldSave(active, tilt: 20)
            for wrapper in [["name": "o", "config": old], ["format": "deep-field-preset", "version": 1, "name": "o", "config": old]] as [[String: Any]] {
                guard let p = PresetStore.preset(from: wrapper) else { expect(false, "\(active): an old preset didn't load"); continue }
                let was = load(old) ?? d
                expect(p.applied(over: was) == was, "\(active): an old preset is no longer current")
                expect(tilted.allSatisfy { shown(p.applied(over: now), $0) == 20 }, "\(active): an old preset's tilt")
                // once the settings are saved in the new format and the preset isn't
                let resaved = saved(was) ?? d
                expect(p.applied(over: resaved) == resaved, "\(active): an old preset isn't current after a new save")
            }
        }

        // a reset puts back that scene's tilt and no other's, from any scene, after an upgrade too
        for active in all {
            var upgraded = load(oldSave(.comet, tilt: 20)) ?? d
            upgraded.scene = active
            for c in [distinct(d, active: active), upgraded] {
                for kind in all {
                    let r = c.resettingScene(kind)
                    let want = kind.hasTilt ? shown(c).merging([kind: WallpaperConfig.defaultTilt]) { $1 } : shown(c)
                    expect(shown(r) == want, "on \(active), resetting \(kind) changed other tilts")
                    expect(c.isCustomized(kind) == kind.hasTilt, "on \(active), \(kind)'s tilt and its Reset disagree")
                    expect(!r.isCustomized(kind) && saved(r) == r && r.scene == active, "on \(active), resetting \(kind) isn't finished")
                }
            }
        }

        // the reset help names the scenes a reset really reaches
        let noon = Date(timeIntervalSince1970: 1_790_000_000)
        for kind in SceneKind.listed {
            var reached: Set<SceneKind> = []
            let before = ConfigKeys.object(d), old = d.stillSettings(SceneKind.listed, at: noon)
            for key in WallpaperConfig.sceneKeys(kind) where key != "tilt" {
                let path = key.split(separator: ".").map(String.init)
                let value = ConfigKeys.value(at: path, in: before)
                let changed: Any
                if ConfigKeys.isColor(value) { changed = ["r": 0.25, "g": 0.5, "b": 0.125] }
                else if ConfigKeys.isBool(value) { changed = !(value as? Bool ?? false) }
                else if let n = value as? Double { changed = n + 1 }
                else { continue }
                let c = load(ConfigKeys.setting(changed, at: path, in: before)) ?? d
                let new = c.stillSettings(SceneKind.listed, at: noon)
                for other in SceneKind.listed where other != kind && old[other] != new[other] { reached.insert(other) }
            }
            var text = kind.sharedNote ?? "", named: Set<SceneKind> = []
            // longest first: "Black Hole" is in other titles
            for other in all.sorted(by: { $0.title.count > $1.title.count }) where text.contains(other.title) {
                named.insert(other)
                text = text.replacingOccurrences(of: other.title, with: "")
            }
            expect(named == reached, "\(kind)'s reset reaches \(reached.map(\.title).sorted()), its help names \(named.map(\.title).sorted())")
        }

        // the command line acts on the current scene, or the one named in the same command
        func set(_ list: [String], on c: WallpaperConfig) -> (config: WallpaperConfig, warnings: [String])? {
            (try? ConfigKeys.assignments(list)).flatMap { try? ConfigKeys.apply($0, to: c, listedScenesOnly: false) }
        }
        for active in all {
            let c = distinct(d, active: active), before = shown(c)
            for kind in all {
                for list in [["scene=\(kind.rawValue)", "tilt=24.5"], ["tilt=24.5", "scene=\(kind.rawValue)"]] {
                    let got = set(list, on: c)
                    expect(got?.config.scene == kind, "\(list) on \(active) didn't switch")
                    expect(got.map { shown($0.config) } == (kind.hasTilt ? before.merging([kind: 24.5]) { $1 } : before), "\(list) on \(active)")
                    expect(got?.warnings == (kind.hasTilt ? [] : ["\(kind.title) has no tilt, so it wasn't changed"]), "\(list) on \(active) warned \(got?.warnings ?? [])")
                }
            }
            let alone = set(["tilt=6.3"], on: c)      // what `reset tilt` applies
            expect(alone.map { shown($0.config) } == (active.hasTilt ? before.merging([active: 6.3]) { $1 } : before), "tilt=6.3 on \(active)")
            expect(set(["bloom=0.5"], on: c).map { shown($0.config) } == before, "another setting on \(active) moved a tilt")
        }
        expect(set(["sceneTilt.comet=3"], on: d) == nil && set(["sharedTilt=3"], on: d) == nil, "parked tilts can be set")
        expect(!ConfigKeys.allPaths(distinct(d, active: .comet)).contains { $0.hasPrefix("sceneTilt") || $0 == "sharedTilt" }, "parked tilts are listed")

        // only the active scene's tilt is part of its look, its bake and its lock screen still
        for active in all {
            let c = distinct(d, active: active)
            for kind in tilted {
                var other = c
                other.scene = kind
                other.tilt = 24.5
                other.scene = active
                let own = kind == active
                expect(c.visibleSettings.isEqual(other.visibleSettings) != own, "\(active)'s look, after \(kind)'s tilt")
                expect((c.bakeKey == other.bakeKey) != own, "\(active)'s bake, after \(kind)'s tilt")
                expect((LockScreenStill.look(c) == LockScreenStill.look(other)) != own, "\(active)'s lock screen still, after \(kind)'s tilt")
                let a = c.stillSettings(all, at: noon), b = other.stillSettings(all, at: noon)
                expect(all.filter { a[$0] != b[$0] } == [kind], "thumbnails due on \(active) after \(kind)'s tilt")
            }
            if !active.hasTilt {
                // a different upgrade is the same picture here
                guard let old = load(oldSave(active, tilt: 20)), let other = load(oldSave(active, tilt: 3)) else { continue }
                expect(old.visibleSettings.isEqual(other.visibleSettings) && old.bakeKey == other.bakeKey
                       && LockScreenStill.look(old) == LockScreenStill.look(other), "\(active) depends on the shared tilt")
            }
        }
        var disrupted = d
        disrupted.scene = .tidalDisruption
        let calm = disrupted.visibleSettings
        disrupted.photonRing = 2
        expect(!calm.isEqual(disrupted.visibleSettings), "the photon ring isn't part of Star Meets Black Hole's look")

        return failures
    }
}
