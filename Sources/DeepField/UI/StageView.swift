import AppKit
import SwiftUI

/// The live wallpaper renderer, embedded. Renders at the main screen's resolution and scales down.
struct LivePreview: NSViewRepresentable {
    let reference: CGSize
    let actualPixels: Bool
    func makeNSView(context: Context) -> WallpaperView { WallpaperView(frame: .zero, previewOf: reference) }
    func updateNSView(_ nsView: WallpaperView, context: Context) { nsView.actualPixels = actualPixels }
}

/// The window's left column: the preview (or the phone preview), a caption and the scrolling
/// scene gallery. Always visible, so every change in the inspector shows at once.
struct StageView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var thumbnails: SceneThumbnails
    let section: CustomizeSection
    let reference: CGSize
    let showPhoneClock: Bool
    @Binding var actualPixels: Bool
    @ObservedObject private var status = StageStatus.shared

    /// `--capture-ui` only: `cacheDisplay` can't read a Metal layer, so captures show a still.
    @State private var captureStill: CGImage?

    var body: some View {
        Group {
            if section == .phone {
                HStack(alignment: .top, spacing: 20) {
                    PhoneStage(store: store, showClock: showPhoneClock)
                    ScrollView { SceneGallery(store: store, thumbnails: thumbnails, columns: 2) }
                }
            } else {
                GeometryReader { geo in
                    let box = previewBox(in: geo.size)
                    VStack(alignment: .leading, spacing: 0) {
                        preview(in: box)
                        caption.frame(width: box.width)
                        // scrolls once the scenes outgrow the window; taller windows show more at once
                        ScrollView {
                            SceneGallery(store: store, thumbnails: thumbnails, columns: galleryColumns(width: geo.size.width))
                                .padding(.vertical, 2)
                        }
                        .padding(.top, 12)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.stagePadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The preview grows with the window: the stage's full width, and as tall as leaves the
    /// caption and one row of the gallery in view.
    private func previewBox(in stage: CGSize) -> CGSize {
        let galleryRow = Theme.gallery(for: reference).box.height + 40
        let height = max(stage.height - 30 - 12 - galleryRow, Theme.previewBox.height * 0.6)
        return CGSize(width: max(stage.width, Theme.previewBox.width), height: height)
    }

    /// As many thumbnail columns as fit the stage, never fewer than the default.
    private func galleryColumns(width: CGFloat) -> Int {
        let base = Theme.gallery(for: reference)
        return max(base.columns, Int((width + 10) / (base.box.width + 10)))
    }

    private func preview(in box: CGSize) -> some View {
        let fitted = Theme.fit(reference, in: box)
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
        .frame(width: box.width)
    }

    private func renderCaptureStill() {
        let px = CGFloat(store.config.pixelSize)
        let w = Int((reference.width / px).rounded(.up)), h = Int((reference.height / px).rounded(.up))
        captureStill = FrameCapture.render(config: store.config, width: w, height: h, time: 300, eventsEnabled: false)
    }

    /// The preview's resolution, plus the frame rate when Low Power Mode or heat caps it.
    private var captionText: String {
        var text = "\(Int(reference.width)) × \(Int(reference.height))"
        let fps = Int(Settings.effectiveFPS)
        if fps < store.config.fps {
            let reason = ProcessInfo.processInfo.isLowPowerModeEnabled && fps == 12 ? "Low Power Mode" : "Thermal limit"
            text += "  ·  \(reason): \(fps) fps"
        }
        return text
    }

    private var caption: some View {
        HStack {
            Group {
                if let message = status.message {
                    Text(message).foregroundStyle(.primary)
                } else {
                    Text(captionText).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 8)
            Picker("Preview scale", selection: $actualPixels) {
                Text("Fit").tag(false)
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
