import AppKit
import SwiftUI

/// The live wallpaper renderer, embedded. Renders at the main screen's resolution and scales down.
private struct LivePreview: NSViewRepresentable {
    let reference: CGSize
    let actualPixels: Bool
    func makeNSView(context: Context) -> WallpaperView { WallpaperView(frame: .zero, previewOf: reference) }
    func updateNSView(_ nsView: WallpaperView, context: Context) { nsView.actualPixels = actualPixels }
}

/// The window's left column: the preview (or the phone preview), a telemetry line and the scene
/// gallery. Always visible, so every change in the inspector shows at once.
struct StageView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var thumbnails: SceneThumbnails
    let section: CustomizeSection
    let reference: CGSize
    let showPhoneClock: Bool
    @Binding var actualPixels: Bool
    @ObservedObject private var status = ConsoleStatus.shared

    /// `--capture-ui` only: `cacheDisplay` can't read a Metal layer, so captures show a still.
    @State private var captureStill: CGImage?

    var body: some View {
        Group {
            if section == .phone {
                HStack(alignment: .top, spacing: 20) {
                    PhoneStage(store: store, showClock: showPhoneClock)
                    SceneGallery(store: store, thumbnails: thumbnails, columns: 2)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    preview
                    telemetry
                    SceneGallery(store: store, thumbnails: thumbnails, columns: 5)
                        .padding(.top, 14)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Theme.stagePadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var preview: some View {
        let fitted = Theme.fit(reference, in: Theme.previewBox)
        return Group {
            if Settings.capturingUI {
                ZStack {
                    Color.black
                    if let captureStill {
                        Image(decorative: captureStill, scale: 1).resizable().interpolation(.high)
                    }
                }
                .onAppear { renderCaptureStill() }
                .onChange(of: store.config) { renderCaptureStill() }
            } else {
                LivePreview(reference: reference, actualPixels: actualPixels)
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .background(Color.black)
        .overlay(Rectangle().stroke(Theme.hairline))
        .overlay(CornerBrackets().stroke(Theme.accent, lineWidth: 2).padding(-5))
        .frame(width: Theme.previewBox.width)
    }

    private func renderCaptureStill() {
        let px = CGFloat(store.config.pixelSize)
        let w = Int((reference.width / px).rounded(.up)), h = Int((reference.height / px).rounded(.up))
        captureStill = FrameCapture.render(config: store.config, width: w, height: h, time: 300, eventsEnabled: false)
    }

    private var telemetryText: String {
        let c = store.config
        let fps = Settings.effectiveFPS
        var parts = [
            "TARGET \(c.scene.title)",
            "\(Int(reference.width))×\(Int(reference.height))",
            "\(c.pixelSize) PX",
            "\(c.levels) LEVELS",
            "\(Int(fps)) FPS" + (fps < Double(c.fps) ? " (CAPPED)" : ""),
        ]
        parts = parts.map { $0.uppercased() }
        return parts.joined(separator: "  ·  ")
    }

    private var telemetry: some View {
        HStack {
            Group {
                if let message = status.message {
                    Text(message.uppercased()).foregroundStyle(Theme.accent)
                } else {
                    Text(telemetryText).foregroundStyle(.secondary)
                }
            }
            .font(Theme.readout)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 8)
            Picker("Preview scale", selection: $actualPixels) {
                Text("FIT").tag(false)
                Text("1:1").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 96)
            .help("1:1 shows the middle of the screen at true pixel size")
        }
        .frame(height: 30)
    }
}
