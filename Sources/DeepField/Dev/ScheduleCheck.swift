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
