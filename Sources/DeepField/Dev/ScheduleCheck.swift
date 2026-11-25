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
        for round in -3...20 {
            let order = WallpaperSchedule.shuffled(3, round: round)
            expect(order.sorted() == [0, 1, 2], "shuffle round \(round) isn't a permutation")
            expect(order.first != WallpaperSchedule.shuffled(3, round: round - 1).last, "shuffle repeats at round \(round)")
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

        if failures.isEmpty { print("schedule OK") } else { failures.forEach { print("FAIL:", $0) } }
        return failures.isEmpty
    }
}
