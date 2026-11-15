import AppKit
import SwiftUI

/// Two columns: the stage (preview, telemetry, scene gallery) and the inspector (a section bar
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
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                SectionBar(selection: $section)
                DitherBand()
                inspector
            }
            .frame(width: Theme.inspectorWidth - 1)
            .background(Theme.panel)
        }
        .frame(width: Theme.windowSize.width, height: Theme.windowSize.height)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: section) { if section == .phone { actualPixels = false } }
        .onAppear { thumbnails.start() }
        .onDisappear { thumbnails.stop() }
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
