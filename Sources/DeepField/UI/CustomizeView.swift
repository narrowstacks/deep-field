import AppKit
import SwiftUI

/// The live wallpaper renderer, embedded. Renders at the main screen's resolution and scales down.
private struct LivePreview: NSViewRepresentable {
    let reference: CGSize
    func makeNSView(context: Context) -> WallpaperView { WallpaperView(frame: .zero, previewOf: reference) }
    func updateNSView(_ nsView: WallpaperView, context: Context) {}
}

struct CustomizeView: View {
    @ObservedObject private var store = ConfigStore.shared

    private var reference: CGSize {
        guard let s = NSScreen.main else { return CGSize(width: 2880, height: 1800) }
        return CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
    }

    var body: some View {
        VStack(spacing: 0) {
            LivePreview(reference: reference)
                .aspectRatio(reference.width / reference.height, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
            TabView {
                SceneTab(store: store).tabItem { Text("Scene") }
                ColorsTab(store: store).tabItem { Text("Colors") }
                SkyTab(store: store).tabItem { Text("Sky & Events") }
                PlanetsTab(store: store).tabItem { Text("Planets") }
                DisplayTab(store: store).tabItem { Text("Display") }
            }
            .padding(12)
        }
        .frame(width: 820, height: 830)
    }
}
