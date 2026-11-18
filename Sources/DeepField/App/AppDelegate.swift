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

    /// Clicking the Dock icon (or opening the app again from Finder) opens Customize.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Settings.capturingUI { showCustomize() }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // a UI capture never touches desktop pictures or the network
        if !Settings.capturingUI { Updater.start() }
        let args = CommandLine.arguments
        // On a first launch the desktop stays as it was until the welcome guide says otherwise.
        let welcome = Settings.isFirstLaunch && !Settings.capturingUI && !args.contains("--customize")
        if welcome { Settings.wallpaperEnabled = false }
        buildWindows()
        buildStatusItem()
        NSApp.mainMenu = MainMenu.build(target: self)
        if !Settings.capturingUI {
            CLIServer.start()
            LockScreenStill.shared.start()
            Scheduler.shared.start()
            LocationProvider.shared.refreshIfFollowing()
        } else {
            LiveEarthFeeds.shared.allowNetwork = false
        }
        if let i = args.firstIndex(of: "--capture-ui"), i + 1 < args.count {
            CustomizeWindowController.shared.captureForDebug(to: args[i + 1])
        } else if let i = args.firstIndex(of: "--capture-welcome"), i + 1 < args.count {
            WelcomeWindowController.shared.captureForDebug(to: args[i + 1], step: Settings.welcomeStep)
        } else if args.contains("--customize") {
            CustomizeWindowController.shared.show()
        } else if welcome || args.contains("--welcome") {
            showWelcome()
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
        let screens = Settings.wallpaperEnabled || Settings.capturingUI ? NSScreen.screens : []
        windows = screens.map { screen in
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

    // MARK: welcome guide

    @objc private func showWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeShown")
        WelcomeWindowController.shared.show { [weak self] setWallpaper in
            if setWallpaper { self?.setWallpaper(true) }
        }
    }

    func setWallpaper(_ on: Bool) {
        Settings.wallpaperEnabled = on
        buildWindows()
    }

    @objc private func toggleWallpaper() { setWallpaper(!Settings.wallpaperEnabled) }

    // MARK: menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Deep Field")
        let menu = NSMenu()
        menu.delegate = self
        pauseItem.target = self
        wallpaperItem.target = self
        menu.addItem(wallpaperItem)
        menu.addItem(pauseItem)
        let customize = NSMenuItem(title: "Customize…", action: #selector(showCustomize), keyEquivalent: ",")
        customize.target = self
        menu.addItem(customize)
        presetsItem.submenu = NSMenu()
        menu.addItem(presetsItem)
        scheduleItem.target = self
        menu.addItem(scheduleItem)
        skipItem.target = self
        menu.addItem(skipItem)
        menu.addItem(.separator())
        lockScreenItem.target = self
        menu.addItem(lockScreenItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let guide = NSMenuItem(title: "Welcome Guide…", action: #selector(showWelcome), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let about = NSMenuItem(title: "About Deep Field", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        if Updater.isAvailable {
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Deep Field", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func showAbout() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Animated, pixel-dithered space wallpapers.\ngithub.com/narrowstacks/deep-field",
                                         attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func checkForUpdates() { Updater.checkForUpdates() }

    private let presetsItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
    private let wallpaperItem = NSMenuItem(title: "Show on Desktop", action: #selector(toggleWallpaper), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
    private let scheduleItem = NSMenuItem(title: "Change on Schedule", action: #selector(toggleSchedule), keyEquivalent: "")
    private let skipItem = NSMenuItem(title: "Next in Schedule", action: #selector(skipSchedule), keyEquivalent: "")
    private let lockScreenItem = NSMenuItem(title: "Use Scene on Lock Screen", action: #selector(toggleLockScreen), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    /// Refreshed on every open, since the login item can also be changed in System Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildPresetsMenu()
        wallpaperItem.state = Settings.wallpaperEnabled ? .on : .off
        pauseItem.title = userPaused ? "Resume Animation" : "Pause Animation"
        pauseItem.isHidden = !Settings.wallpaperEnabled
        lockScreenItem.state = ConfigStore.shared.config.lockScreenStill ? .on : .off
        let schedule = ScheduleStore.shared.schedule
        scheduleItem.state = schedule.enabled ? .on : .off
        // with nothing scheduled yet, the item opens Customize to set it up
        scheduleItem.title = schedule.entries.isEmpty ? "Set Up Schedule…" : "Change on Schedule"
        skipItem.isHidden = !(schedule.enabled && schedule.mode == .rotate && schedule.entries.count > 1)
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed   // registered, waiting for approval in System Settings
        default: loginItem.state = .off
        }
    }

    // MARK: presets

    private func rebuildPresetsMenu() {
        guard let sub = presetsItem.submenu else { return }
        sub.removeAllItems()
        let store = PresetStore.shared
        let current = store.current
        if store.presets.isEmpty {
            let empty = NSMenuItem(title: "No saved presets yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        }
        for preset in store.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = preset.id == current?.id ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        for (title, action) in [("Save Current Settings as Preset…", #selector(savePreset)),
                                ("Import Preset…", #selector(importPreset)),
                                ("Export Current Settings…", #selector(exportPreset))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            sub.addItem(item)
        }
    }

    @objc private func applyPreset(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID,
              let preset = PresetStore.shared.presets.first(where: { $0.id == id }) else { return }
        PresetStore.shared.apply(preset)
    }
    @objc private func savePreset() { PresetStore.shared.promptToSave() }
    @objc private func importPreset() { PresetStore.shared.promptToImport() }
    @objc private func exportPreset() { PresetStore.shared.promptToExport(nil) }

    @objc private func toggleSchedule() {
        if ScheduleStore.shared.schedule.entries.isEmpty {
            CustomizeWindowController.shared.show(section: .schedule)
        } else {
            ScheduleStore.shared.schedule.enabled.toggle()
        }
    }
    @objc private func skipSchedule() { Scheduler.shared.skip() }
    @objc private func togglePause() { userPaused.toggle(); applyPause() }

    /// The menu bar's Pause Animation, for the command line.
    var animationPaused: Bool {
        get { userPaused }
        set { userPaused = newValue; applyPause() }
    }
    @objc func showCustomize() { CustomizeWindowController.shared.show() }
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
