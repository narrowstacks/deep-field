import AppKit
import Sparkle

/// Sparkle updates for release builds. Dev runs (no bundle, or no feed URL in Info.plist)
/// skip it, so `swift run` and the dev CLI never touch the network.
enum Updater {
    private static var controller: SPUStandardUpdaterController?

    static var isAvailable: Bool { controller != nil }

    static func start() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Settings saved under the app's earlier bundle identifiers move to the current one, once.
enum DefaultsMigration {
    static func run() {
        let d = UserDefaults.standard
        guard d.object(forKey: "migratedFromLocalID") == nil else { return }
        d.set(true, forKey: "migratedFromLocalID")
        guard let current = Bundle.main.bundleIdentifier, current != "local.deepfield.wallpaper",
              let old = d.persistentDomain(forName: "local.deepfield.wallpaper") else { return }
        for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
    }
}
