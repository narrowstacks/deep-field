import SwiftUI

/// Changing the wallpaper over time: rotate through presets and scenes, or switch at set times
/// on chosen days, each switch moving into the next with a transition.
struct ScheduleTab: View {
    @ObservedObject private var schedules = ScheduleStore.shared
    @ObservedObject private var presets = PresetStore.shared
    // observed for the status line: switches, the clock and Focus filters, and changes by hand
    @ObservedObject private var scheduler = Scheduler.shared
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        let s = $schedules.schedule
        let schedule = schedules.schedule
        Form {
            Section {
                Toggle("Change the wallpaper on a schedule", isOn: s.enabled)
                Picker("Mode", selection: s.mode) {
                    ForEach(WallpaperSchedule.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if schedule.mode == .rotate {
                    Picker("Every", selection: s.intervalMinutes) {
                        ForEach(WallpaperSchedule.intervals.including(schedule.intervalMinutes), id: \.self) { Text(Self.interval($0)).tag($0) }
                    }
                    Toggle("Shuffle", isOn: s.shuffle)
                        .help("A new order each time round, never showing the same look twice in a row")
                }
                Picker("Transition", selection: s.transition) {
                    ForEach(TransitionStyle.allCases) { style in
                        if style == .random { Divider() }
                        Text(style.title).tag(style)
                    }
                }
                .help(schedule.transition.help)
                Picker("Length", selection: s.fadeSeconds) {
                    ForEach(WallpaperSchedule.fades.including(schedule.fadeSeconds), id: \.self) { Text(Self.length($0)).tag($0) }
                }
                .help("How long each switch takes")
            } header: {
                GroupHeader(title: "Schedule")
            } footer: {
                GroupFooter(scheduler.status)
            }

            Section {
                if schedule.entries.isEmpty {
                    Text(schedule.mode == .rotate ? "Add presets or scenes to rotate through."
                                                  : "Add presets or scenes and the times they start.")
                        .foregroundStyle(.secondary)
                }
                ForEach(s.entries) { $entry in
                    EntryRow(entry: $entry, number: (schedule.entries.firstIndex { $0.id == entry.id } ?? 0) + 1,
                             mode: schedule.mode, presets: presets.presets,
                             canMoveUp: entry.id != schedule.entries.first?.id,
                             moveUp: { move(entry.id) }, delete: { schedules.schedule.entries.removeAll { $0.id == entry.id } })
                }
                HStack {
                    addMenu
                    Spacer()
                    if schedule.mode == .rotate && schedule.enabled && schedule.entries.count > 1 {
                        Button("Next Now") { Scheduler.shared.skip() }
                            .help("Moves on to the next look and starts the interval over")
                    }
                }
            } header: {
                GroupHeader(title: schedule.mode == .rotate ? "Rotation" : "Times")
            } footer: {
                GroupFooter(schedule.mode == .rotate
                    ? "Presets bring their whole look; a scene keeps your current settings. Changes you make by hand stay until the next switch."
                    : "Each one holds until the next starts, overnight too. A Focus filter takes precedence while it's on.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var addMenu: some View {
        Menu("Add") {
            Section("Presets") {
                if presets.presets.isEmpty { Text("No saved presets yet") }
                ForEach(presets.presets) { p in Button(p.name) { add(.preset(p.id)) } }
            }
            Section("Scenes") {
                ForEach(SceneKind.listed) { k in Button(k.title) { add(.scene(k)) } }
            }
        }
        .fixedSize()
    }

    /// A new timed entry starts an hour after the last one, so two don't land on the same time.
    private func add(_ target: ScheduleTarget) {
        var e = ScheduleEntry(target: target)
        if let last = schedules.schedule.entries.last { e.minute = (last.minute + 60) % (24 * 60) }
        schedules.schedule.entries.append(e)
    }

    private func move(_ id: UUID) {
        guard let i = schedules.schedule.entries.firstIndex(where: { $0.id == id }), i > 0 else { return }
        schedules.schedule.entries.swapAt(i, i - 1)
    }

    static func interval(_ minutes: Double) -> String {
        switch minutes {
        case 60: "Hour"
        case 1440: "Day"
        case 120... where minutes.truncatingRemainder(dividingBy: 60) == 0: "\(ConfigKeys.number(minutes / 60)) hours"
        default: "\(ConfigKeys.number(minutes)) min"
        }
    }

    static func length(_ seconds: Double) -> String { seconds == 0 ? "Instant" : "\(ConfigKeys.number(seconds)) s" }
}

private struct EntryRow: View {
    @Binding var entry: ScheduleEntry
    /// Its place in the list, which VoiceOver tells rows apart by: two can show the same look.
    let number: Int
    let mode: WallpaperSchedule.Mode
    let presets: [UserPreset]
    let canMoveUp: Bool
    let moveUp: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if mode == .timed {
                    DatePicker("Entry \(number) starts", selection: time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                }
                Picker("Entry \(number) shows", selection: $entry.target) {
                    if !presets.contains(where: { .preset($0.id) == entry.target }), case .preset = entry.target {
                        Text("Deleted preset").tag(entry.target)
                    }
                    Section("Presets") {
                        ForEach(presets) { Text($0.name).tag(ScheduleTarget.preset($0.id)) }
                    }
                    Section("Scenes") {
                        ForEach(SceneKind.listed) { Text($0.title).tag(ScheduleTarget.scene($0)) }
                    }
                }
                .labelsHidden()
                Menu {
                    if mode == .rotate { Button("Move Up", action: moveUp).disabled(!canMoveUp) }
                    Button("Remove", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("Entry \(number) options")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if mode == .timed { weekdays }
        }
    }

    /// Minutes after midnight as a time of day, for the time picker.
    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: entry.minute / 60, minute: entry.minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            entry.minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    /// One toggle per day, starting on the locale's first weekday.
    private var weekdays: some View {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let days = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        return HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let on = entry.weekdays.contains(day)
                Button(symbols[day - 1]) {
                    if on { if entry.weekdays.count > 1 { entry.weekdays.remove(day) } } else { entry.weekdays.insert(day) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(on ? .accentColor : nil)
                .opacity(on ? 1 : 0.45)
                .help(cal.weekdaySymbols[day - 1])
                .accessibilityLabel("Entry \(number), \(cal.weekdaySymbols[day - 1])")
                .accessibilityHint("")   // the tooltip would repeat the day
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}
