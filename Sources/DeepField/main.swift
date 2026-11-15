import AppKit
import ServiceManagement

enum Settings {
    private static let d = UserDefaults.standard
    static var debug: Bool { d.bool(forKey: "debug") }
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

final class WallpaperWindow: NSWindow {
    let wallpaper: WallpaperView

    init(screen: NSScreen) {
        wallpaper = WallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // Desktop level: below every app window and below Finder's desktop icons.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = wallpaper
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WallpaperWindow] = []
    private var statusItem: NSStatusItem!
    private var userPaused = false
    private var screensAsleep = false
    private var sessionInactive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindows()
        buildStatusItem()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--capture-ui"), i + 1 < args.count {
            CustomizeWindowController.shared.captureForDebug(to: args[i + 1])
        } else if args.contains("--customize") {
            CustomizeWindowController.shared.show()
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true; self?.applyPause()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false; self?.applyPause()
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionInactive = true; self?.applyPause()
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionInactive = false; self?.applyPause()
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.windows.forEach { $0.wallpaper.settingsChanged() }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildWindows()
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.windows.forEach { $0.wallpaper.settingsChanged() }
            }
        }
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = WallpaperWindow(screen: screen)
            w.orderFrontRegardless() // the desktop window level keeps it beneath everything

            return w
        }
        applyPause()
    }

    private func applyPause() {
        let paused = userPaused || screensAsleep || sessionInactive
        windows.forEach { $0.wallpaper.externallyPaused = paused }
    }

    // MARK: menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Deep Field")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let pause = NSMenuItem(title: userPaused ? "Resume Animation" : "Pause Animation",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let customize = NSMenuItem(title: "Customize…", action: #selector(showCustomize), keyEquivalent: ",")
        customize.target = self
        menu.addItem(customize)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Deep Field", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func togglePause() { userPaused.toggle(); applyPause(); rebuildMenu() }
    @objc private func showCustomize() { CustomizeWindowController.shared.show() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("DeepField: login item change failed: \(error)")
        }
        rebuildMenu()
    }
}

Snapshot.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
