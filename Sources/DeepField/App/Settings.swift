import Foundation

/// Runtime flags from UserDefaults (`defaults write com.narrowstacks.DeepField <key> -bool true`).
enum Settings {
    private static let d = UserDefaults.standard
    static var debug: Bool { d.bool(forKey: "debug") }
    /// Dev only: the Customize section `--capture-ui` opens on (pass `-captureTab N`: 0 Scene,
    /// 1 Sky, 2 Image, 3 System, 4 Phone; anything else is Scene).
    static var captureTab: Int { d.integer(forKey: "captureTab") }
    /// Dev only: the window is being captured to an image, so the preview is drawn as a still.
    static var capturingUI: Bool {
        CommandLine.arguments.contains("--capture-ui") || CommandLine.arguments.contains("--capture-welcome")
    }
    /// Dev only: the welcome guide step `--capture-welcome` opens on (`-welcomeStep N`, 0 to 3).
    static var welcomeStep: Int { d.integer(forKey: "welcomeStep") }

    /// Whether the scene is on the desktop. Off until the first-launch guide finishes with Set as
    /// Wallpaper, and switchable from the menu bar.
    static var wallpaperEnabled: Bool {
        get { d.object(forKey: "wallpaperEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "wallpaperEnabled") }
    }

    /// True on a first launch: no saved settings, no earlier version's keys, and the guide not yet
    /// seen. Worked out once at startup, before anything saves.
    static let isFirstLaunch: Bool = {
        let keys = ["welcomeShown", "config", "SUHasLaunchedBefore", "fps", "pixelSize", "levels", "migratedFromLocalID"]
        let seen = keys.contains { d.object(forKey: $0) != nil }
            || UserDefaults(suiteName: "local.eventhorizon.wallpaper")?.data(forKey: "config") != nil
        return !seen
    }()
    /// Testing only: keep rendering even when the desktop is covered.
    static var ignoreOcclusion: Bool { d.bool(forKey: "ignoreOcclusion") }

    /// Frame rate after power and thermal caps.
    static var effectiveFPS: Double {
        var f = Double(ConfigStore.shared.config.fps)
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { f = min(f, 12) }
        if info.thermalState == .serious || info.thermalState == .critical { f = min(f, 8) }
        return f
    }
}
