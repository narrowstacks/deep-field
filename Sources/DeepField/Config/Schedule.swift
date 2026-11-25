import Foundation
import Combine

/// What a schedule entry switches to: a saved preset (its whole look), or a scene (keeping the
/// current settings, as picking it in the gallery does).
enum ScheduleTarget: Codable, Hashable {
    case preset(UUID)
    case scene(SceneKind)

    func title(in presets: [UserPreset]) -> String {
        switch self {
        case let .preset(id): presets.first { $0.id == id }?.name ?? "Deleted preset"
        case let .scene(kind): kind.title
        }
    }

    /// The config this target makes from `current`, or nil if its preset is gone.
    func applied(over current: WallpaperConfig,
                 presets: [UserPreset] = PresetStore.shared.presets) -> WallpaperConfig? {
        switch self {
        case let .preset(id):
            return presets.first { $0.id == id }?.applied(over: current)
        case let .scene(kind):
            guard kind.isListed else { return nil }
            var c = current
            c.scene = kind
            return c
        }
    }
}

/// How one look gives way to the next (see `transitionFragment`).
enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case dissolve, crossfade, pan, driftAway, warp, blackHole, random
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dissolve: "Dissolve"
        case .crossfade: "Crossfade"
        case .pan: "Pan"
        case .driftAway: "Drift Away"
        case .warp: "Warp"
        case .blackHole: "Black Hole"
        case .random: "Random"
        }
    }

    var help: String {
        switch self {
        case .dissolve: "The new scene grows in from soft, dithered patches"
        case .crossfade: "One scene fades into the other"
        case .pan: "The camera slides over to the new scene"
        case .driftAway: "The old scene's objects float off into the distance as the new one settles in"
        case .warp: "Fly forward through the old scene into the new one"
        case .blackHole: "A black hole sweeps across, bending light, with the new scene behind it"
        case .random: "A different transition each time"
        }
    }

    /// The styles Random picks from.
    static var concrete: [TransitionStyle] { allCases.filter { $0 != .random } }

    var resolved: TransitionStyle { self == .random ? Self.concrete.randomElement()! : self }

    var shaderIndex: Float { Float(Self.concrete.firstIndex(of: resolved) ?? 0) }
}

struct ScheduleEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var target: ScheduleTarget
    /// Timed mode: when it starts, in minutes after midnight, local time.
    var minute = 9 * 60
    /// Timed mode: the days it starts on, as `Calendar` weekdays (1 = Sunday ... 7 = Saturday).
    var weekdays: Set<Int> = Set(1...7)
}

/// Changes the wallpaper over time. Rotate steps through the entries every `intervalMinutes`
/// (in order or shuffled); Timed switches to each entry at its time of day on its weekdays, and
/// holds it until the next one. Each switch takes `fadeSeconds`, in the `transition` style.
struct WallpaperSchedule: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case rotate, timed
        var id: String { rawValue }
        var title: String { self == .rotate ? "Rotate" : "At Set Times" }
    }

    var enabled = false
    var mode: Mode = .rotate
    var entries: [ScheduleEntry] = []
    var intervalMinutes: Double = 60
    var shuffle = false
    var fadeSeconds: Double = 8
    var transition: TransitionStyle = .dissolve
    /// Rotation counts whole intervals from here, so the order survives relaunches.
    var anchor = Date()
    /// Added to the step to get the place in the rotation, so an edit can move the current entry's
    /// place while the step, and with it the slot's key, stays the same.
    var shift = 0
    /// An entry removed while it was the current one, which stays current until its step ends.
    struct Removed: Codable, Equatable {
        let entry: ScheduleEntry
        let step: Int
    }
    var removed: Removed?

    static let intervals: [Double] = [1, 5, 15, 30, 60, 120, 240, 480, 1440]
    static let fades: [Double] = [0, 2, 4, 8, 15, 30, 60]

    init() {}

    /// Lenient, like the config: a key missing from an older save keeps its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperSchedule()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
        entries = (try? c.decodeIfPresent([ScheduleEntry].self, forKey: .entries)) ?? d.entries
        intervalMinutes = (try? c.decodeIfPresent(Double.self, forKey: .intervalMinutes)) ?? d.intervalMinutes
        shuffle = (try? c.decodeIfPresent(Bool.self, forKey: .shuffle)) ?? d.shuffle
        fadeSeconds = (try? c.decodeIfPresent(Double.self, forKey: .fadeSeconds)) ?? d.fadeSeconds
        transition = (try? c.decodeIfPresent(TransitionStyle.self, forKey: .transition)) ?? d.transition
        anchor = (try? c.decodeIfPresent(Date.self, forKey: .anchor)) ?? d.anchor
        shift = (try? c.decodeIfPresent(Int.self, forKey: .shift)) ?? d.shift
        removed = (try? c.decodeIfPresent(Removed.self, forKey: .removed)) ?? d.removed
    }

    /// The entry that should be showing at `date`, and a key that changes exactly when a new
    /// switch is due (a new rotation step, or a new timed start), so a relaunch or a manual edit
    /// in between doesn't repeat one.
    struct Slot: Equatable {
        let entry: ScheduleEntry
        let key: String
        /// When the next switch is due, if there is one.
        let next: Date?
    }

    func slot(at date: Date, calendar: Calendar = .current) -> Slot? {
        guard !entries.isEmpty else { return nil }
        switch mode {
        case .rotate: return rotationSlot(at: date)
        case .timed: return timedSlot(at: date, calendar: calendar)
        }
    }

    private func rotationSlot(at date: Date) -> Slot {
        let step = step(at: date)
        let entry = removed?.step == step ? removed!.entry : entry(atStep: step)
        return Slot(entry: entry, key: "rotate \(step) \(entry.id) \(entry.target)",
                    next: anchor.addingTimeInterval(Double(step + 1) * interval))
    }

    private var interval: TimeInterval { max(intervalMinutes, 1) * 60 }

    private func step(at date: Date) -> Int { Int(floor(date.timeIntervalSince(anchor) / interval)) }

    private func entry(atStep step: Int) -> ScheduleEntry {
        let n = entries.count, place = step + shift
        let index = ((place % n) + n) % n
        return entries[shuffle ? Self.shuffled(n, round: Int(floor(Double(place) / Double(n))))[index] : index]
    }

    /// This schedule as it should run when it replaces `old` at `now`. A rotation that was already
    /// running keeps its current entry and goes on from there; one that wasn't starts at the top.
    func continued(from old: WallpaperSchedule, at now: Date) -> WallpaperSchedule {
        guard enabled, mode == .rotate, !entries.isEmpty else { return self }
        var s = self
        // whole seconds, so counting steps back from here can't round into the step before
        let seconds = now.timeIntervalSinceReferenceDate.rounded(.down)
        guard old.enabled, old.mode == .rotate, !old.entries.isEmpty else {
            s.anchor = Date(timeIntervalSinceReferenceDate: seconds)
            // the time picks the shuffled round (or which of two goes first), so starts differ
            s.shift = Int(seconds) * (shuffle && entries.count == 2 ? 1 : entries.count)
            s.removed = nil
            return s
        }
        let step = old.step(at: now)
        if interval != old.interval {
            // a full interval from now: counted from the last switch, the next could be overdue
            s.anchor = Date(timeIntervalSinceReferenceDate: seconds - Double(step) * interval)
        }
        guard shuffle != old.shuffle || entries.map(\.id) != old.entries.map(\.id) else { return s }

        // Line up the current entry with this step or, if it's gone, the first one left of those
        // that were to follow with the next step. Two rounds reach them all when shuffled.
        let current = old.rotationSlot(at: now).entry
        let index = entries.firstIndex { $0.id == current.id }
        s.removed = index == nil ? Removed(entry: current, step: step) : nil
        let following = (step + 1...step + 2 * old.entries.count).lazy
            .compactMap { i in entries.firstIndex { $0.id == old.entry(atStep: i).id } }
        let first = index ?? following.first ?? 0
        let place: Int
        if shuffle, entries.count > 2 {    // every round of two starts with the same one
            // a round that starts with it, so every other entry shows before any repeats
            var round = Int(seconds)
            while Self.shuffled(entries.count, round: round)[0] != first { round += 1 }
            place = round * entries.count
        } else {
            place = first
        }
        s.shift = place - (index == nil ? step + 1 : step)
        return s
    }

    /// A fixed shuffle per round, seeded by the round number. A round never starts with the
    /// entry the round before ended on, so the same look doesn't show twice in a row. Two entries
    /// can only alternate, so all their rounds are the same; with more, the swap leaves the last
    /// entry alone, so the round before needn't be swapped to compare with it.
    static func shuffled(_ n: Int, round: Int) -> [Int] {
        guard n > 2 else { return Array(0..<n) }
        func order(_ r: Int) -> [Int] {
            var rng = SplitMix(seed: UInt64(bitPattern: Int64(r)) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
            var a = Array(0..<n)
            for i in stride(from: n - 1, to: 0, by: -1) { a.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            return a
        }
        var a = order(round)
        if a.first == order(round - 1).last { a.swapAt(0, 1) }
        return a
    }

    /// The latest start at or before `date` across the past week, and the first one after it.
    private func timedSlot(at date: Date, calendar: Calendar) -> Slot? {
        var best: (Date, ScheduleEntry)?, next: Date?
        let today = calendar.startOfDay(for: date)
        for offset in -7...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            for entry in entries where entry.weekdays.contains(weekday) {
                guard let start = calendar.date(bySettingHour: entry.minute / 60, minute: entry.minute % 60,
                                                second: 0, of: day) else { continue }
                if start <= date {
                    // later entries win a tie, like the last line of a list
                    if best == nil || start >= best!.0 { best = (start, entry) }
                } else if next == nil || start < next! {
                    next = start
                }
            }
        }
        guard let (start, entry) = best else { return nil }
        return Slot(entry: entry, key: "timed \(Int(start.timeIntervalSince1970)) \(entry.id) \(entry.target)", next: next)
    }
}

/// A small seeded generator, so a shuffle is the same on every launch.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The schedule, kept in UserDefaults apart from the look, so presets never carry it.
final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()
    private let key = "schedule"

    @Published private var current: WallpaperSchedule

    /// Computed, so an edit is continued from the old schedule before it's stored, rather than by
    /// a second assignment that would set off another change.
    var schedule: WallpaperSchedule {
        get { current }
        set {
            let old = current, new = newValue.continued(from: old, at: Date())
            guard new != old else { return }
            current = new
            if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: key) }
            Scheduler.shared.scheduleChanged(from: old)
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(WallpaperSchedule.self, from: data) {
            current = s
        } else {
            current = WallpaperSchedule()
        }
    }
}
