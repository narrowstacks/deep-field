import AppKit

/// One borderless window per screen, at desktop level, holding that screen's wallpaper view.
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
