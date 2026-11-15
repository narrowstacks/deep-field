import AppKit
import ServiceManagement

/// Menu bar item, one wallpaper window per screen, and pausing when nobody can see them.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [WallpaperWindow] = []
    private var statusItem: NSStatusItem!
    private var userPaused = false
    private var screensAsleep = false
    private var sessionInactive = false

    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindows()
        buildStatusItem()
        LockScreenStill.shared.start()
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
            self?.windows.forEach { $0.wallpaper.systemStateChanged() }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buildWindows()
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.windows.forEach { $0.wallpaper.systemStateChanged() }
            }
        }
    }

    /// One window per screen. Windows of screens that are still attached are kept (and moved if
    /// the arrangement changed), so a screen change doesn't re-bake every display; only windows
    /// of screens that went away are torn down.
    private func buildWindows() {
        var old = windows
        windows = NSScreen.screens.map { screen in
            if let id = WallpaperWindow.displayID(of: screen), let i = old.firstIndex(where: { $0.displayID == id }) {
                let w = old.remove(at: i)
                w.place(on: screen)
                return w
            }
            let w = WallpaperWindow(screen: screen)
            w.orderFrontRegardless()   // the desktop window level keeps it beneath everything
            return w
        }
        old.forEach { $0.tearDown() }
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
        let menu = NSMenu()
        menu.delegate = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        let customize = NSMenuItem(title: "Customize…", action: #selector(showCustomize), keyEquivalent: ",")
        customize.target = self
        menu.addItem(customize)
        menu.addItem(.separator())
        lockScreenItem.target = self
        menu.addItem(lockScreenItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Deep Field", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private let pauseItem = NSMenuItem(title: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
    private let lockScreenItem = NSMenuItem(title: "Use Scene on Lock Screen", action: #selector(toggleLockScreen), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    /// Refreshed on every open, since the login item can also be changed in System Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = userPaused ? "Resume Animation" : "Pause Animation"
        lockScreenItem.state = ConfigStore.shared.config.lockScreenStill ? .on : .off
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed   // registered, waiting for approval in System Settings
        default: loginItem.state = .off
        }
    }

    @objc private func togglePause() { userPaused.toggle(); applyPause() }
    @objc private func showCustomize() { CustomizeWindowController.shared.show() }
    @objc private func toggleLockScreen() { ConfigStore.shared.config.lockScreenStill.toggle() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSLog("DeepField: login item change failed: \(error)")
        }
    }
}
