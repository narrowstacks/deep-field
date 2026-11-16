import AppKit

/// Runs the schedule: works out which entry is due, switches to it with a transition, and sets a
/// timer for the next switch. Each switch happens once, when its slot begins (see
/// `WallpaperSchedule.Slot.key`), so changes made by hand in between stay until the next one.
/// A Focus filter takes precedence: nothing switches while one is on.
final class Scheduler {
    static let shared = Scheduler()

    private var timer: Timer?
    private var started = false
    private let lastKey = "scheduleLastSlot"

    private var store: ScheduleStore { .shared }

    /// Called once at launch. The first switch cuts straight over, since nothing is on screen yet.
    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.evaluate()
            }
        }
        evaluate(fade: false)
    }

    func scheduleChanged(from old: WallpaperSchedule) {
        guard started else { return }
        // turning it on shows the current entry now, even if its slot was already shown
        if store.schedule.enabled && !old.enabled { UserDefaults.standard.removeObject(forKey: lastKey) }
        evaluate()
    }

    /// Rotation only: moves on to the next entry now, and starts the interval over from here.
    func skip() {
        var s = store.schedule
        guard s.mode == .rotate, let next = s.slot(at: Date())?.next else { return }
        s.anchor = s.anchor.addingTimeInterval(-next.timeIntervalSinceNow)
        store.schedule = s
    }

    private var focusActive: Bool { UserDefaults.standard.data(forKey: "focusRestoreConfig") != nil }

    func evaluate(fade: Bool = true) {
        timer?.invalidate()
        timer = nil
        let s = store.schedule
        guard s.enabled, let slot = s.slot(at: Date()) else { return }
        if let next = slot.next {
            let t = Timer(fire: next.addingTimeInterval(0.2), interval: 0, repeats: false) { [weak self] _ in
                self?.evaluate()
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        let d = UserDefaults.standard
        guard !focusActive, d.string(forKey: lastKey) != slot.key else { return }
        let store = ConfigStore.shared
        // a deleted preset leaves the wallpaper as it is
        if let new = slot.entry.target.applied(over: store.config) {
            store.transition(to: new, seconds: fade ? s.fadeSeconds : 0, style: s.transition)
        }
        d.set(slot.key, forKey: lastKey)
    }
}
