import Foundation

/// `--check-schedule`: checks which entry a schedule picks over time, on plain schedules,
/// without touching the saved settings.
enum ScheduleCheck {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let a = ScheduleEntry(target: .scene(.galaxy)), b = ScheduleEntry(target: .scene(.comet)),
            c = ScheduleEntry(target: .scene(.pulsar))

        // rotation steps every interval and wraps around
        var r = WallpaperSchedule()
        r.entries = [a, b, c]
        r.intervalMinutes = 30
        r.anchor = date(2026, 11, 16, 9, 0)
        let picks = (0..<6).map { r.slot(at: r.anchor.addingTimeInterval(Double($0) * 1800 + 60))!.entry.id }
        expect(picks == [a.id, b.id, c.id, a.id, b.id, c.id], "rotation order")
        let s0 = r.slot(at: r.anchor.addingTimeInterval(60))!, s1 = r.slot(at: r.anchor.addingTimeInterval(1700))!
        expect(s0.key == s1.key, "rotation key changed within a step")
        expect(s0.next == r.anchor.addingTimeInterval(1800), "rotation next switch")

        // a shuffled round covers every entry once and never repeats across a round boundary
        let bases = [-800_000_000, 800_000_000, 1_000_000_000_000]
        for n in 1...12 {
            for round in Array(-60...60) + bases.flatMap({ $0...($0 + 60) }) {
                let order = WallpaperSchedule.shuffled(n, round: round)
                expect(order.sorted() == Array(0..<n), "shuffle of \(n), round \(round) isn't a permutation")
                expect(n == 1 || order.first != WallpaperSchedule.shuffled(n, round: round - 1).last,
                       "shuffle of \(n) repeats at round \(round)")
            }
        }
        // saved rotations of three or more depend on these orders, so they can't change
        for (round, order) in [(-1, [2, 0, 1]), (2, [2, 1, 0]), (-7, [1, 3, 2, 4, 0]), (800_000_000, [3, 0, 1, 4, 2]),
                               (817_000_000, [9, 1, 4, 6, 2, 8, 11, 10, 3, 7, 0, 5])] {
            expect(WallpaperSchedule.shuffled(order.count, round: round) == order, "shuffle of \(order.count), round \(round) changed")
        }

        // editing a running rotation keeps the current slot (entry, key and next switch) and goes on from it
        r.enabled = true
        let now = r.anchor.addingTimeInterval(4 * 1800 + 1201.3)    // b, for the second time; seconds that aren't a multiple of 3
        let before = r.slot(at: now)!
        func edited(_ s: WallpaperSchedule, _ edit: (inout WallpaperSchedule) -> Void) -> WallpaperSchedule {
            var new = s
            edit(&new)
            return new.continued(from: s, at: now)
        }
        func upcoming(_ s: WallpaperSchedule, _ count: Int) -> [UUID] {
            let first = s.slot(at: now)!.next!
            return (0..<count).map { s.slot(at: first.addingTimeInterval((Double($0) + 0.5) * s.intervalMinutes * 60))!.entry.id }
        }
        let d = ScheduleEntry(target: .scene(.eclipse))
        let added = edited(r) { $0.entries.insert(d, at: 0) }
        expect(added.slot(at: now) == before, "adding an entry changed the slot")
        expect(upcoming(added, 4) == [c.id, d.id, a.id, b.id], "order after adding")
        let cut = edited(r) { $0.entries.removeFirst() }
        expect(cut.slot(at: now) == before, "removing another entry changed the slot")
        expect(upcoming(cut, 2) == [c.id, b.id], "order after removing another entry")
        let moved = edited(r) { $0.entries.swapAt(1, 0) }
        expect(moved.slot(at: now) == before, "reordering changed the slot")
        expect(upcoming(moved, 3) == [a.id, c.id, b.id], "order after reordering")

        // removing the current entry leaves its slot until the next switch, through more edits
        var held = edited(r) { $0.entries.remove(at: 1) }
        expect(held.slot(at: now) == before, "removing the current entry changed the slot")
        expect(upcoming(held, 3) == [c.id, a.id, c.id], "order after removing the current entry")
        held = edited(held) { $0.entries = [d, c, a] }
        expect(held.slot(at: now) == before, "reordering after removing the current entry changed the slot")
        expect(upcoming(held, 3) == [c.id, a.id, d.id], "order after removing the current entry and reordering")
        for i in held.entries.indices {
            expect(edited(held) { $0.entries[i].target = .scene(.blackHole) }.slot(at: now) == before,
                   "changing another entry's target after removing the current one")
        }
        held = edited(held) { $0.entries.remove(at: 1) }
        expect(held.slot(at: now) == before, "removing the next entry too changed the slot")
        expect(upcoming(held, 2) == [a.id, d.id], "order after removing the next entry too")
        let replaced = edited(r) { $0.entries = [d] }
        expect(replaced.slot(at: now) == before && upcoming(replaced, 1) == [d.id], "replacing every entry")

        // changing the current entry's target is a new switch, at once
        let target = edited(r) { $0.entries[1].target = .scene(.eclipse) }.slot(at: now)!
        expect(target.key != before.key && target.entry.id == b.id && target.next == before.next, "changing the current target")

        // a new interval counts from now, even when the current step has already lasted longer
        for minutes in WallpaperSchedule.intervals where minutes != 30 {
            let s = edited(r) { $0.intervalMinutes = minutes }, slot = s.slot(at: now)!
            expect(slot.key == before.key && upcoming(s, 2) == [c.id, a.id], "interval \(minutes) changed the slot")
            expect(abs(slot.next!.timeIntervalSince(now) - minutes * 60) <= 1, "interval \(minutes) next switch")
            let h = edited(edited(r) { $0.entries.remove(at: 1) }) { $0.intervalMinutes = minutes }
            expect(h.slot(at: now)?.key == before.key && upcoming(h, 2) == [c.id, a.id], "interval \(minutes) after removing the current entry")
        }

        // shuffle: the same, and every other entry shows before any repeats
        let mixed = edited(r) { $0.shuffle = true }
        expect(mixed.slot(at: now) == before, "turning shuffle on changed the slot")
        expect(Set(upcoming(mixed, 2)) == [a.id, c.id], "round after turning shuffle on")
        let grown = edited(mixed) { $0.entries.insert(d, at: 0) }
        expect(grown.slot(at: now) == before, "adding while shuffled changed the slot")
        expect(Set(upcoming(grown, 3)) == [a.id, c.id, d.id], "round after adding while shuffled")
        let reversed = edited(grown) { $0.entries.reverse() }
        expect(reversed.slot(at: now) == before, "reordering while shuffled changed the slot")
        let next = upcoming(grown, 1)
        let shrunk = edited(grown) { $0.entries.removeAll { $0.id == b.id } }
        expect(shrunk.slot(at: now) == before && upcoming(shrunk, 1) == next, "removing the current entry while shuffled")
        expect(Set(upcoming(shrunk, 3)) == [a.id, c.id, d.id], "round after removing the current entry while shuffled")
        let pair = edited(mixed) { $0.entries.remove(at: 0) }
        expect(pair.slot(at: now) == before && upcoming(pair, 1) == [c.id], "two entries left while shuffled")
        let sorted = edited(grown) { $0.shuffle = false }
        expect(sorted.slot(at: now) == before && upcoming(sorted, 2) == [c.id, d.id], "turning shuffle off")

        // two shuffled entries alternate from whichever is current, however they came to be two
        for current in [a, b] {
            let other = current == a ? b : a
            func alternates(_ s: WallpaperSchedule, _ what: String) {
                expect(s.slot(at: now)?.entry == current, "\(what): the current entry changed")
                expect(upcoming(s, 40) == (0..<40).map { ($0 % 2 == 0 ? other : current).id }, "\(what): doesn't alternate")
            }
            var two = r
            two.entries = [a, b]
            two.shift = current == a ? 0 : 1    // step 4
            let on = edited(two) { $0.shuffle = true }
            alternates(on, "shuffling two")
            alternates(edited(on) { $0.entries.reverse() }, "reordering two shuffled")
            alternates(edited(on) { $0.intervalMinutes = 5 }, "a new interval for two shuffled")
            alternates(edited(edited(on) { $0.shuffle = false }) { $0.shuffle = true }, "shuffling two again")
            let three = edited(on) { $0.entries.insert(c, at: 1) }
            alternates(edited(three) { $0.entries.remove(at: 1) }, "down to two shuffled")
            let one = edited(on) { $0.entries = [current] }
            expect(one.slot(at: now) == on.slot(at: now) && upcoming(one, 2) == [current.id, current.id], "down to one shuffled")
            alternates(edited(one) { $0.entries = [a, b] }, "back to two shuffled")

            let gone = edited(three) { $0.entries = [c, other] }, after = upcoming(gone, 40)
            expect(gone.slot(at: now) == three.slot(at: now) && after.first == upcoming(three, 1).first
                   && zip(after, after.dropFirst()).allSatisfy { $0 != $1 }, "removing the current entry, down to two shuffled")
            let last = edited(on) { $0.entries = [other] }
            expect(last.slot(at: now) == on.slot(at: now) && upcoming(last, 2) == [other.id, other.id],
                   "removing the current entry, down to one shuffled")
        }
        // turning it on can start with either, and alternates from there
        var started: Set<UUID> = []
        for second in 0..<2 {
            let on = now.addingTimeInterval(Double(second))
            var s = WallpaperSchedule()
            s.entries = [a, b]
            s.shuffle = true
            let off = s
            s.enabled = true
            s = s.continued(from: off, at: on)
            let shown = (0..<40).map { s.slot(at: on.addingTimeInterval(Double($0) * 3600))!.entry.id }
            started.insert(shown[0])
            expect(zip(shown, shown.dropFirst()).allSatisfy { $0 != $1 }, "turning on two shuffled: doesn't alternate")
        }
        expect(started == [a.id, b.id], "turning on two shuffled always starts with the same one")

        // edits that don't touch a running rotation's order or pace are stored as they are
        let unrelated: [(inout WallpaperSchedule) -> Void] = [
            { $0.anchor -= 1200 }, { $0.fadeSeconds = 2 }, { $0.enabled = false; $0.entries.removeFirst() },
            { $0.mode = .timed; $0.entries.removeFirst() }, { $0.entries = [] }]
        for edit in unrelated {
            var s = grown
            edit(&s)
            expect(s.continued(from: grown, at: now) == s, "an unrelated edit moved the rotation")
        }
        // Next Now moves the anchor, past an entry that was removed
        let skipped = edited(held) { $0.anchor -= before.next!.timeIntervalSince(now) + 0.1 }
        expect(skipped.slot(at: now)?.entry.id == a.id && upcoming(skipped, 1) == [d.id], "Next Now after removing the current entry")

        for s in [r, held, grown, shrunk] {
            let saved = try? JSONDecoder().decode(WallpaperSchedule.self, from: JSONEncoder().encode(s))
            expect(saved == s, "saving and loading changed the schedule")
        }
        let older = try? JSONDecoder().decode(WallpaperSchedule.self, from: Data(#"{"enabled": true, "anchor": 0}"#.utf8))
        expect(older?.enabled == true && older?.shift == 0 && older?.removed == nil
               && older?.anchor == Date(timeIntervalSinceReferenceDate: 0), "an older save")

        // starting (turned on, back from set times, or its first entry) is at the top with a full interval
        var off = held, times = r, empty = r
        off.enabled = false
        off.removed = .init(entry: b, step: 0)    // a start is at step 0, and clears it
        times.mode = .timed
        empty.entries = []
        for (what, old) in [("turning on", off), ("leaving set times", times), ("the first entry", empty)] {
            for shuffle in [false, true] {
                let s = edited(old) { $0.enabled = true; $0.mode = .rotate; $0.entries = [a, b, c]; $0.shuffle = shuffle }
                let slot = s.slot(at: now)!
                expect(abs(slot.next!.timeIntervalSince(now) - 1800) <= 1, "\(what): not a full interval")
                expect(shuffle || slot.entry.id == a.id, "\(what): not the first entry")
                expect(Set([slot.entry.id] + upcoming(s, 2)) == [a.id, b.id, c.id], "\(what): not a whole round")
            }
        }

        // timed: the latest start wins, held across midnight and skipped on other weekdays
        var t = WallpaperSchedule()
        t.mode = .timed
        var morning = a, evening = b, weekend = c
        morning.minute = 7 * 60; evening.minute = 19 * 60 + 30
        weekend.minute = 10 * 60; weekend.weekdays = [1, 7]          // Sunday, Saturday
        t.entries = [morning, evening, weekend]
        // 2026-11-16 is a Monday
        expect(t.slot(at: date(2026, 11, 16, 6, 0), calendar: cal)?.entry.id == evening.id, "before 7 keeps last night's")
        expect(t.slot(at: date(2026, 11, 16, 7, 0), calendar: cal)?.entry.id == morning.id, "7:00 switches to morning")
        expect(t.slot(at: date(2026, 11, 16, 12, 0), calendar: cal)?.entry.id == morning.id, "noon is still morning")
        expect(t.slot(at: date(2026, 11, 16, 20, 0), calendar: cal)?.entry.id == evening.id, "evening")
        expect(t.slot(at: date(2026, 11, 16, 12, 0), calendar: cal)?.next == date(2026, 11, 16, 19, 30), "timed next")
        // Saturday 2026-11-21: morning at 7, the weekend entry from 10
        expect(t.slot(at: date(2026, 11, 21, 11, 0), calendar: cal)?.entry.id == weekend.id, "weekend entry")
        expect(t.slot(at: date(2026, 11, 23, 8, 0), calendar: cal)?.entry.id == morning.id, "weekday after a weekend")
        // a key per start: the same entry on two days switches twice
        expect(t.slot(at: date(2026, 11, 16, 8, 0), calendar: cal)?.key != t.slot(at: date(2026, 11, 17, 8, 0), calendar: cal)?.key,
               "timed key repeats across days")
        // across the March DST change, 7:00 is still 7:00 local
        expect(t.slot(at: date(2027, 3, 14, 7, 1), calendar: cal)?.entry.id == morning.id, "DST morning")

        var only = WallpaperSchedule()
        only.mode = .timed
        var one = a
        one.weekdays = [4]    // Wednesday
        only.entries = [one]
        expect(only.slot(at: date(2026, 11, 16, 12, 0), calendar: cal)?.entry.id == one.id, "a single weekly entry holds all week")
        expect(WallpaperSchedule().slot(at: Date()) == nil, "an empty schedule picks nothing")

        // the status line
        let preset = UserPreset(name: "Dusk", config: WallpaperConfig())
        let p = ScheduleEntry(target: .preset(preset.id))
        var plan = WallpaperSchedule()
        plan.enabled = true
        plan.entries = [a, p]
        plan.intervalMinutes = 1440
        plan.anchor = now
        func statusCheck(_ what: String, _ begins: String, next: Bool = true, entry: Int = 0,
                         _ change: (inout ScheduleStatus) -> Void) {
            let at = now.addingTimeInterval(Double(entry) * 86400 + 60)
            var look = WallpaperConfig()
            look.sceneImage["comet"] = ImageSettings(look)
            look.scene = entry == 0 ? .galaxy : .blackHole
            var s = ScheduleStatus(schedule: plan, config: look, presets: [preset],
                                   lastSlot: plan.slot(at: at)!.key, lastLook: look)
            change(&s)
            let text = s.text(at: at)
            expect(text.hasPrefix(begins) && text.contains("Next switch") == next, "status, \(what): \(text)")
        }
        let byHand = "Changed by hand since the last switch. Next switch "
        statusCheck("scene", "Now: Galaxy. Next switch ") { _ in }
        statusCheck("preset", "Now: Dusk. Next switch ", entry: 1) { _ in }
        statusCheck("off", "Off.", next: false) { $0.schedule.enabled = false; $0.focusActive = true }
        statusCheck("empty", "Nothing to show yet.", next: false) { $0.schedule.entries = [] }
        statusCheck("Focus", "A Focus filter is choosing the wallpaper. The schedule resumes when it ends.", next: false) {
            $0.focusActive = true
            $0.config.scene = .comet
        }
        statusCheck("another scene", byHand) { $0.config.scene = .comet }
        statusCheck("the scene's settings", byHand) { $0.config.galaxyArms += 1 }
        statusCheck("the sky", byHand) { $0.config.nebula += 0.1 }
        statusCheck("a preset's settings", byHand, entry: 1) { $0.config.bloom += 0.1 }
        statusCheck("a color", byHand, entry: 1) { $0.config.palette.ring = RGB(0.1, 0.2, 0.3) }

        // what isn't a change by hand
        statusCheck("the Mac's settings and place", "Now: Galaxy.") {
            $0.config.fps = 60
            $0.config.lockScreenStill = true
            $0.config.lockScreenSmooth = true
            $0.config.homeFromDevice = true
            $0.config.homeLatitude = 12.34
            $0.config.homeLongitude = 56.78
        }
        statusCheck("another scene's settings", "Now: Galaxy.") {
            $0.config.scene = .comet
            $0.config.cometTailLength = 2
            $0.config.bloom = 1    // comet has its own image settings, so galaxy's stay
            $0.config.scene = .galaxy
            $0.config.diskSize = 20
            $0.config.palette.receding = RGB(0.1, 0.2, 0.3)
        }
        statusCheck("after a relaunch", "Now: Galaxy.") {
            var c = $0.config
            c.saturation = 1.0 / 3
            c.nebula = 0.1 + 0.2
            c.galaxyPitch = .pi
            c.levels = 1    // clamped when read back
            $0.lastLook = c
            $0.config = (try? JSONEncoder().encode(c)).flatMap(WallpaperConfig.decode) ?? WallpaperConfig()
        }
        statusCheck("a color that saving migrates", "Now: Dusk.", entry: 1) {
            $0.config.scene = .comet
            $0.config.cometIonColor = WallpaperConfig.Tuned.cometIon.light
            $0.lastLook = (try? JSONEncoder().encode($0.config)).flatMap(WallpaperConfig.decode)
        }
        // tilt: its own scene's only, and the same look in a save from when all scenes shared one
        func tilt(_ scene: SceneKind, _ x: Double) -> (inout ScheduleStatus) -> Void {
            { s in
                let active = s.config.scene
                s.config.scene = scene
                s.config.tilt = x
                s.config.scene = active
            }
        }
        statusCheck("the scene's tilt", byHand, entry: 1, tilt(.blackHole, 20))
        statusCheck("another scene's tilt", "Now: Dusk.", entry: 1, tilt(.comet, 20))
        statusCheck("another scene's tilt on one without", "Now: Galaxy.", tilt(.comet, 20))
        statusCheck("Star Meets Black Hole's photon ring", byHand) {
            $0.config.scene = .tidalDisruption
            $0.lastLook = $0.config
            $0.config.photonRing += 0.5
        }
        for kind in SceneKind.listed {
            let old = { (x: Double) in
                (try? JSONSerialization.data(withJSONObject: TiltCheck.oldSave(kind, tilt: x))).flatMap(WallpaperConfig.decode) ?? WallpaperConfig()
            }
            statusCheck("upgrading on \(kind)", "Now: Galaxy.") { $0.lastLook = old(20); $0.config = old(20) }
            statusCheck("upgrading on \(kind), then saving", "Now: Galaxy.") {
                $0.lastLook = old(20)
                $0.config = (try? JSONEncoder().encode(old(20))).flatMap(WallpaperConfig.decode) ?? WallpaperConfig()
                if kind != .comet { tilt(.comet, 9)(&$0) }
            }
            statusCheck("a tilt changed before upgrading on \(kind)", kind.hasTilt ? byHand : "Now: Galaxy.") { $0.lastLook = old(20); $0.config = old(8) }
            // a switch brings the scene's own tilt, and leaves the last scene's to come back to
            var c = old(20)
            c.scene = .comet
            c.tilt = 9
            let there = ScheduleTarget.scene(kind).applied(over: c, presets: [])!
            expect(there.tilt == (kind == .comet ? 9 : 20) && there.scene == kind, "a scheduled \(kind) shows another scene's tilt")
            expect(ScheduleTarget.scene(.comet).applied(over: there, presets: []) == c, "a scheduled switch to \(kind) and back changed a tilt")
        }
        let sky: [(inout WallpaperConfig) -> Void] = [
            { $0.starDensity += 0.1 }, { $0.nebula += 0.1 }, { $0.galaxies.toggle() }, { $0.milkyWay.toggle() },
            { $0.skySeed += 1 }, { $0.twinkles = .off }, { $0.twinkleBrightness += 0.1 }, { $0.twinkleSpeed += 0.1 },
            { $0.pulsars.toggle() }, { $0.supernovae = .off }, { $0.comets = .off },
            { $0.palette.nebulaA = RGB(0, 0, 1) }, { $0.palette.nebulaB = RGB(0, 0, 1) },
            { $0.palette.galaxy = RGB(0, 0, 1) }, { $0.palette.starWarm = RGB(0, 0, 1) },
            { $0.palette.starCool = RGB(0, 0, 1) }]
        for (i, edit) in sky.enumerated() {
            for (scene, begins) in [(SceneKind.liveEarth, "Now: Galaxy."), (.galaxy, byHand)] {
                statusCheck("sky setting \(i) on \(scene)", begins) {
                    $0.config.scene = scene
                    $0.lastLook = $0.config
                    edit(&$0.config)
                }
            }
        }
        statusCheck("the preset edited later", "Now: Dusk.", entry: 1) { $0.presets[0].config.bloom += 0.5 }
        statusCheck("the preset saved over with the look", "Now: Dusk.", entry: 1) {
            $0.config.bloom += 0.5
            $0.presets[0].config = $0.config
        }
        statusCheck("a switch by an older version", "Now: Galaxy.") { $0.lastLook = nil; $0.config.scene = .comet }
        statusCheck("a switch about to happen", "Now: Galaxy.") { $0.lastSlot = "another"; $0.config.scene = .comet }

        // presets renamed or deleted, and entries removed
        let deleted = "The scheduled preset was deleted, so the wallpaper stays as it is. Next switch "
        statusCheck("renamed", "Now: Dawn. Next switch ", entry: 1) { $0.presets[0].name = "Dawn" }
        statusCheck("deleted", deleted, entry: 1) { $0.presets = [] }
        statusCheck("deleted before its switch", deleted, entry: 1) {
            $0.presets = []
            $0.config.scene = .comet
            $0.lastLook = $0.config
        }
        statusCheck("deleted, then changed", byHand, entry: 1) { $0.presets = []; $0.config.scene = .comet }
        func remove(_ s: inout ScheduleStatus) {
            let old = s.schedule
            s.schedule.entries.remove(at: 0)
            s.schedule = s.schedule.continued(from: old, at: now.addingTimeInterval(60))
        }
        statusCheck("removed", "Now: Galaxy (removed from the schedule). Next switch ") { remove(&$0) }
        statusCheck("removed, then changed", byHand) { remove(&$0); $0.config.scene = .comet }
        statusCheck("removed before it showed", "The scheduled look was removed before it could show. Next switch ") {
            remove(&$0)
            $0.lastSlot = "another"
        }

        // intervals and lengths the pickers don't list are added to them, under names of their own
        expect(WallpaperSchedule.intervals.including(90) == [1, 5, 15, 30, 60, 90, 120, 240, 480, 1440], "a 90 minute interval isn't listed")
        expect(WallpaperSchedule.fades.including(2.5) == [0, 2, 2.5, 4, 8, 15, 30, 60], "a 2.5 s length isn't listed")
        expect([0.5, 45, 90, 2880].map(ScheduleTab.interval) == ["0.5 min", "45 min", "90 min", "48 hours"], "interval names")
        expect(WallpaperSchedule.intervals.map(ScheduleTab.interval)
               == ["1 min", "5 min", "15 min", "30 min", "Hour", "2 hours", "4 hours", "8 hours", "Day"], "usual interval names")
        expect([0, 2, 2.5, 60].map(ScheduleTab.length) == ["Instant", "2 s", "2.5 s", "60 s"], "length names")

        if failures.isEmpty { print("schedule OK") } else { failures.forEach { print("FAIL:", $0) } }
        return failures.isEmpty
    }
}
