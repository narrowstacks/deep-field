import Foundation

/// The Schedule section's line on what's showing and what comes next. It works from plain values,
/// so `--check-schedule` can cover it without the saved settings.
struct ScheduleStatus {
    var schedule: WallpaperSchedule
    var config: WallpaperConfig
    var presets: [UserPreset]
    var focusActive = false
    /// The key of the slot last switched to, and the look that switch left on screen (nil after
    /// one made by a version that didn't keep it).
    var lastSlot: String?
    var lastLook: WallpaperConfig?

    func text(at now: Date, calendar: Calendar = .current) -> String {
        guard schedule.enabled else { return "Off. Your wallpaper stays as you set it." }
        guard let slot = schedule.slot(at: now, calendar: calendar) else {
            return schedule.entries.isEmpty ? "Nothing to show yet." : "Nothing has started yet."
        }
        if focusActive { return "A Focus filter is choosing the wallpaper. The schedule resumes when it ends." }
        var text = showing(slot)
        if let next = slot.next {
            let f = DateFormatter()
            f.dateStyle = calendar.isDateInToday(next) ? .none : .short
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            text += " Next switch \(f.string(from: next))."
        }
        return text
    }

    private func showing(_ slot: WallpaperSchedule.Slot) -> String {
        let removed = !schedule.entries.contains { $0.id == slot.entry.id }
        if removed && lastSlot != slot.key { return "The scheduled look was removed before it could show." }
        if lastSlot == slot.key, changedByHand(slot.entry.target) { return "Changed by hand since the last switch." }
        if case let .preset(id) = slot.entry.target, !presets.contains(where: { $0.id == id }) {
            return "The scheduled preset was deleted, so the wallpaper stays as it is."
        }
        return "Now: \(slot.entry.target.title(in: presets))\(removed ? " (removed from the schedule)" : "")."
    }

    /// Compared with the look right after the switch: what the entry would apply now is no guide,
    /// since a scene keeps any settings and a preset can be edited. A preset saved over with the
    /// current look is showing, though, so that isn't a change.
    private func changedByHand(_ target: ScheduleTarget) -> Bool {
        guard let lastLook else { return false }
        let look = config.visibleSettings
        if look.isEqual(lastLook.visibleSettings) { return false }
        guard case .preset = target, let now = target.applied(over: config, presets: presets) else { return true }
        return !look.isEqual(now.visibleSettings)
    }
}
