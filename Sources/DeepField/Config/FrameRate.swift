/// The frame rates Customize offers, and which display link ticks draw at one.
enum FrameRate {
    static let standard = [12, 24, 30, 60]
    /// Above the refresh rate of any display (the fastest sold are 600 Hz and up). The display link
    /// never ticks faster than its display, so a higher rate runs at the display's maximum.
    static let limit = 1000

    /// The usual rates, each display's refresh rate, and the saved rate whatever set it.
    static func choices(displays: [Int], current: Int) -> [Int] {
        (standard + displays.filter { (1...limit).contains($0) }).including(current)
    }

    /// The display link may tick faster than asked on high refresh displays, so ticks too soon
    /// after the last frame are skipped. The quarter's slack keeps jitter from dropping frames.
    static func isDue(after elapsed: Double, fps: Double) -> Bool { elapsed >= 0.75 / fps }
}

extension Array where Element: Hashable & Comparable {
    /// These in order without repeats, plus the current value, so a picker always has it to show
    /// whatever set it (a preset, the command line, a hand-edited save).
    func including(_ current: Element) -> [Element] { Set(self + [current]).sorted() }
}
