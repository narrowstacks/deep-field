import Foundation
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
            config = c
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.config) else { return }
            UserDefaults.standard.set(data, forKey: self.key)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func demo(_ kind: EventSchedule.Kind) {
        demoEvents[kind.id] = Renderer.shared.elapsed
    }
}
