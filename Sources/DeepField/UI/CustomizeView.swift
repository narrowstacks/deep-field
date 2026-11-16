import AppKit
import SwiftUI

/// Two columns: the stage (preview, caption, scene gallery) and the inspector (a section picker
/// and that section's controls). Dark in both system appearances, since colors are judged
/// against a black sky.
struct CustomizeView: View {
    @ObservedObject private var store = ConfigStore.shared
    @StateObject private var thumbnails = SceneThumbnails(reference: CustomizeView.reference)
    /// Normally Scene; `-captureTab N` picks another for `--capture-ui`.
    @State private var section = CustomizeSection(rawValue: Settings.captureTab) ?? .scene
    /// Owned here so the stage's phone preview and the Phone section share it.
    @State private var showPhoneClock = true
    @State private var actualPixels = false

    /// The main screen's size in pixels: the preview renders exactly what it would show.
    static var reference: CGSize {
        guard let s = NSScreen.main else { return CGSize(width: 2880, height: 1800) }
        return CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
    }

    var body: some View {
        HStack(spacing: 0) {
            StageView(store: store, thumbnails: thumbnails, section: section, reference: Self.reference,
                      showPhoneClock: showPhoneClock, actualPixels: $actualPixels)
                .frame(width: Theme.stageWidth)
                .background(Theme.stageBackground)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("Section", selection: $section) {
                        ForEach(CustomizeSection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    PresetsMenu()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
                inspector
            }
            .frame(maxWidth: .infinity)
            .background(Theme.inspectorBackground)
        }
        .frame(width: Theme.windowSize.width, height: Theme.windowSize.height)
        .preferredColorScheme(.dark)
        .background { shortcuts }
        .onChange(of: section) { if section == .phone { actualPixels = false } }
        .onAppear { thumbnails.start() }
        .onDisappear { thumbnails.stop() }
    }

    /// The app has no main menu (it's a menu bar app), so the window's keys live here: Cmd-1 to
    /// Cmd-5 pick a section, Cmd-[ and Cmd-] step through the scenes, Cmd-W closes. Invisible
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
        }
    }
}
