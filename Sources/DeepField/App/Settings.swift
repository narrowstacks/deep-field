import Foundation

/// Runtime flags from UserDefaults (`defaults write com.narrowstacks.DeepField <key> -bool true`).
enum Settings {
    private static let d = UserDefaults.standard
    static var debug: Bool { d.bool(forKey: "debug") }
    /// Dev only: the Customize section `--capture-ui` opens on (pass `-captureTab N`: 0 Scene,
    /// 1 Sky, 2 Image, 3 System, 4 Phone; anything else is Scene).
    static var captureTab: Int { d.integer(forKey: "captureTab") }
    /// Dev only: the window is being captured to an image, so the preview is drawn as a still.
    static var capturingUI: Bool { CommandLine.arguments.contains("--capture-ui") }
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
