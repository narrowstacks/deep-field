import AppKit
import SwiftUI

final class CustomizeWindowController {
    static let shared = CustomizeWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: CustomizeView()))
            w.title = "Customize Deep Field"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
