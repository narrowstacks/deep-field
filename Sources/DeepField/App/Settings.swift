import Foundation

/// Runtime flags from UserDefaults (`defaults write local.deepfield.wallpaper <key> -bool true`).
enum Settings {
    private static let d = UserDefaults.standard
    static var debug: Bool { d.bool(forKey: "debug") }
    /// Dev only: the Customize tab `--capture-ui` opens on (pass `-captureTab N`).
    static var captureTab: Int { d.integer(forKey: "captureTab") }
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
