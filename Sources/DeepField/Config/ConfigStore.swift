import AppKit
import Combine

/// Holds the live config, persists it, and tells every view when it changes.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    static let changed = Notification.Name("DeepFieldConfigChanged")

    private let key = "config"
    private var saveWork: DispatchWorkItem?

    @Published var config: WallpaperConfig {
        didSet {
            guard config != oldValue else { return }
            NotificationCenter.default.post(name: Self.changed, object: nil)
            scheduleSave()
        }
    }

    /// A change that transitions in over `duration` seconds instead of cutting (the schedule's
    /// switches). Views compare `id` to tell a new transition from one they've already started.
    struct Transition {
        let id: Int
        let from: WallpaperConfig
        let start: Double      // Renderer.elapsed when it began
        let duration: Double
        let style: TransitionStyle   // never .random; that's resolved when it starts
    }
    private(set) var transition: Transition?

    /// Switches to `new`, transitioning from the current look over `seconds` (0 cuts straight over).
    func transition(to new: WallpaperConfig, seconds: Double, style: TransitionStyle = .dissolve) {
        guard new != config else { return }
        if seconds > 0 {
            transition = Transition(id: (transition?.id ?? 0) + 1, from: config,
                                    start: Renderer.shared.elapsed, duration: seconds, style: style.resolved)
        }
        config = new
    }

    /// Transient "show me now" requests from the customize window: event kind id -> start time.
    @Published var demoEvents: [UInt64: Double] = [:]

    private init() {
        let d = UserDefaults.standard
        // one-time carry-over of settings saved under the app's earlier name
        if d.data(forKey: key) == nil, let old = UserDefaults(suiteName: "local.eventhorizon.wallpaper")?.data(forKey: key) {
            d.set(old, forKey: key)
        }
        if let data = d.data(forKey: key), var c = WallpaperConfig.decode(data) {
            if !c.scene.isListed { c.scene = .blackHole }
            config = c
        } else {
            var c = WallpaperConfig()
            // carry over settings from the menu-only version
            if d.integer(forKey: "fps") > 0 { c.fps = d.integer(forKey: "fps") }
            if d.integer(forKey: "pixelSize") > 0 { c.pixelSize = d.integer(forKey: "pixelSize") }
            if d.integer(forKey: "levels") > 0 { c.levels = d.integer(forKey: "levels") }
            config = c.sanitized()
        }
    }

    /// Saves are debounced, so dragging a slider writes once when it settles.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes a pending save now (at quit, so the last change isn't lost).
    func flush() {
        guard let work = saveWork, !work.isCancelled else { return }
        work.cancel()
        save()
    }

    /// Off for dev captures, so they can switch scenes without touching the saved settings.
    var persists = true

    private func save() {
        saveWork = nil
        guard persists else { return }
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Why a sky event started now couldn't be seen on any display, or nil if it could.
    func hiddenReason(_ kind: EventSchedule.Kind) -> String? {
        let aspects = NSScreen.screens.map { Double($0.frame.width / max($0.frame.height, 1)) }
        return EventSchedule.hiddenReason(kind, config: config, aspects: aspects, at: Renderer.shared.elapsed)
    }

    func demo(_ kind: EventSchedule.Kind) {
        demoEvents[kind.id] = Renderer.shared.elapsed
    }
}
