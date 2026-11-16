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
            let w = NSWindow(contentViewController: NSHostingController(rootView: CustomizeView(initialSection: section)))
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
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in self?.closed() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func closed() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // detach the SwiftUI content once the close finishes, so the preview leaves its window
        // (which invalidates its display link) and is freed along with its bake
        let w = window
        window = nil
        DispatchQueue.main.async { w?.contentViewController = nil }
    }
}
