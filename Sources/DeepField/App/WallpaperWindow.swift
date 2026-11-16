import AppKit

/// One borderless window per screen, at desktop level, holding that screen's wallpaper view.
final class WallpaperWindow: NSWindow {
    let wallpaper: WallpaperView

    init(screen: NSScreen) {
        wallpaper = WallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // One above the desktop level: below every app window and Finder's desktop icons, but
        // above the system's desktop picture. On macOS 14 and 15 the Dock draws each Space's
        // picture at exactly the desktop level, and switching Spaces orders that Space's picture
        // over a window at the same level, so the wallpaper only showed on the Space it started on.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = wallpaper
        displayID = Self.displayID(of: screen)
    }

    /// The screen this window was made for.
    private(set) var displayID: CGDirectDisplayID?

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Follows the screen to a new position or size (the view re-bakes only if the size changed).
    func place(on screen: NSScreen) {
        if frame != screen.frame { setFrame(screen.frame, display: false) }
    }

    /// For a screen that went away: stop drawing and let the view and its bake go.
    func tearDown() {
        orderOut(nil)
        contentView = nil   // detaching the view invalidates its display link
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
