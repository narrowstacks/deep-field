import Foundation
import Combine

/// What a schedule entry switches to: a saved preset (its whole look), or a scene (keeping the
/// current settings, as picking it in the gallery does).
enum ScheduleTarget: Codable, Hashable {
    case preset(UUID)
    case scene(SceneKind)

    var title: String {
        switch self {
        case let .preset(id): PresetStore.shared.presets.first { $0.id == id }?.name ?? "Deleted preset"
        case let .scene(kind): kind.title
        }
    }

    /// The config this target makes from `current`, or nil if its preset is gone.
    func applied(over current: WallpaperConfig) -> WallpaperConfig? {
        switch self {
        case let .preset(id):
            return PresetStore.shared.presets.first { $0.id == id }?.applied(over: current)
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
        let interval = max(intervalMinutes, 1) * 60
        let step = Int(floor(date.timeIntervalSince(anchor) / interval))
        let n = entries.count
        let index = shuffle ? Self.shuffled(n, round: Int(floor(Double(step) / Double(n))))[((step % n) + n) % n]
                            : ((step % n) + n) % n
        let entry = entries[index]
        return Slot(entry: entry, key: "rotate \(step) \(entry.id) \(entry.target)",
                    next: anchor.addingTimeInterval(Double(step + 1) * interval))
    }

    /// A fixed shuffle per round, seeded by the round number. A round never starts with the
    /// entry the round before ended on, so the same look doesn't show twice in a row.
    static func shuffled(_ n: Int, round: Int) -> [Int] {
        func order(_ r: Int) -> [Int] {
            var rng = SplitMix(seed: UInt64(bitPattern: Int64(r)) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
            var a = Array(0..<n)
            for i in stride(from: n - 1, to: 0, by: -1) { a.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            return a
        }
        var a = order(round)
        if n > 1, a.first == order(round - 1).last { a.swapAt(0, 1) }
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

    @Published var schedule: WallpaperSchedule {
        didSet {
            guard schedule != oldValue else { return }
            if let data = try? JSONEncoder().encode(schedule) { UserDefaults.standard.set(data, forKey: key) }
            Scheduler.shared.scheduleChanged(from: oldValue)
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(WallpaperSchedule.self, from: data) {
            schedule = s
        } else {
            schedule = WallpaperSchedule()
        }
    }
}
