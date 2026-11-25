import AppKit
import SwiftUI

/// The Customize window. It's built on demand and thrown away when closed, so its live preview
/// (a full-resolution bake and a display link) doesn't linger for the rest of the day.
final class CustomizeWindowController {
    static let shared = CustomizeWindowController()
    private(set) var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    static let showSection = Notification.Name("DeepFieldShowSection")

    /// Opens the window, on `section` if given (the open window switches to it).
    func show(section: CustomizeSection? = nil) {
        if let section, window != nil {
            NotificationCenter.default.post(name: Self.showSection, object: section)
        }
        if window == nil {
            let thumbnails = SceneThumbnails()
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: CustomizeView(thumbnails: thumbnails, initialSection: section)))
            w.title = "Customize Deep Field"
            // resizable: a taller window shows more of the gallery, a wider one a wider inspector
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(Theme.windowSize)
            w.contentMinSize = CGSize(width: Theme.windowSize.width, height: Theme.minWindowHeight)
            // dark in both system appearances: colors are judged against a black sky
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("CustomizeWindow")   // remembers the size and position you leave it at
            thumbnails.follow(w)
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in self?.closed() }
            window = w
        }
        updateDockIcon()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// In the Dock while this window is open, if the setting is on; a menu bar app otherwise.
    func updateDockIcon() {
        guard !Settings.capturingUI else { return }
        let policy: NSApplication.ActivationPolicy = window != nil && Settings.dockWhileCustomizing ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            guard wasActive else { NSApp.activate(ignoringOtherApps: true); return }
            // an app that's already frontmost keeps the menu bar it had until it's activated
            // again, so hand focus to the Dock for a moment and take it back
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            }
        } else if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            // with no window left, give focus back to the app below instead of keeping an
            // invisible app frontmost (the wallpaper windows can't hide)
            NSApp.hide(nil)
        }
    }

    private func closed() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // detach the SwiftUI content once the close finishes, so the preview leaves its window
        // (which invalidates its display link) and is freed along with its bake
        let w = window
        window = nil
        DispatchQueue.main.async { [weak self] in
            w?.contentViewController = nil
            self?.updateDockIcon()   // once the window is off screen
        }
    }
}
