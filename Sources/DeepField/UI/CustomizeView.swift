import AppKit
import SwiftUI

/// Two columns: the stage (preview, caption, scene gallery) and the inspector (a section picker
/// and that section's controls). Dark in both system appearances, since colors are judged
/// against a black sky.
struct CustomizeView: View {
    @ObservedObject private var store = ConfigStore.shared
    @ObservedObject private var thumbnails: SceneThumbnails
    /// Normally Scene; `-captureTab N` picks another for `--capture-ui`, and the menu bar can ask for one.
    @State private var section: CustomizeSection
    /// Owned here so the stage's phone preview and the Phone section share it.
    @State private var showPhoneClock = true
    @State private var actualPixels = false

    init(thumbnails: SceneThumbnails, initialSection: CustomizeSection? = nil) {
        self.thumbnails = thumbnails
        _section = State(initialValue: initialSection ?? CustomizeSection(rawValue: Settings.captureTab) ?? .scene)
    }

    var body: some View {
        HStack(spacing: 0) {
            StageView(store: store, thumbnails: thumbnails, section: section,
                      showPhoneClock: showPhoneClock, actualPixels: $actualPixels)
                .frame(minWidth: Theme.stageWidth, maxWidth: .infinity)
                .background(Theme.stageBackground)
            Divider()
            VStack(alignment: .trailing, spacing: 12) {
                Picker("Section", selection: $section) {
                    ForEach(CustomizeSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                PresetsMenu()
                inspector
            }
            .padding(.top, 12)
            .padding(.horizontal, 20)
            .frame(width: Theme.inspectorWidth)
            .background(Theme.inspectorBackground)
            .padding(.bottom, 12)
        }
        .frame(minWidth: Theme.windowSize.width, maxWidth: .infinity,
               minHeight: Theme.minWindowHeight, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .background { shortcuts }
        .onChange(of: section) { if section == .phone { actualPixels = false } }
        .onReceive(NotificationCenter.default.publisher(for: CustomizeWindowController.showSection)) {
            if let s = $0.object as? CustomizeSection { section = s }
        }
        .onAppear { thumbnails.start() }
        .onDisappear { thumbnails.stop() }
    }

    /// The app has no main menu (it's a menu bar app), so the window's keys live here: Cmd-1 to
    /// Cmd-6 pick a section, Cmd-[ and Cmd-] step through the scenes, Cmd-W closes. Invisible
    /// buttons rather than `.hidden()`, which can drop the shortcut.
    private var shortcuts: some View {
        ZStack {
            ForEach(CustomizeSection.allCases) { s in
                Button(s.title) { section = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(s.rawValue + 1)")), modifiers: .command)
            }
            Button("Previous scene") { stepScene(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next scene") { stepScene(1) }.keyboardShortcut("]", modifiers: .command)
            Button("Close") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func stepScene(_ step: Int) {
        let scenes = SceneKind.listed
        guard let i = scenes.firstIndex(of: store.config.scene) else { return }
        store.config.scene = scenes[(i + step + scenes.count) % scenes.count]
    }

    /// Only the selected section's views exist.
    @ViewBuilder private var inspector: some View {
        switch section {
        case .scene: SceneTab(store: store)
        case .sky: SkyTab(store: store)
        case .image: ImageTab(store: store)
        case .system: SystemTab(store: store)
        case .phone: PhoneTab(store: store, showClock: $showPhoneClock)
        case .schedule: ScheduleTab()
        }
    }
}
