import SwiftUI

/// The phone preview on the stage while the Phone section is selected, in place of the
/// landscape one. It owns the exporter's preview lifecycle.
struct PhoneStage: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var phone = PhoneExporter.shared
    let showClock: Bool
    /// The stage's height, which the preview and its caption share.
    let stageHeight: CGFloat

    private static let box = CGSize(width: 394, height: 676)
    private static let captionHeight: CGFloat = 30

    var body: some View {
        let options = phone.options
        // the exported size, which is what the preview renders: a typed 0 or negative has no shape
        let width = MobileOptions.clampedSide(options.width), height = MobileOptions.clampedSide(options.height)
        // shrinks to fit short windows; capped so the gallery keeps its room in tall ones
        let boxHeight = min(Self.box.height, max(stageHeight - Self.captionHeight, 1))
        let fitted = Theme.fit(CGSize(width: width, height: height), in: CGSize(width: Self.box.width, height: boxHeight))
        let w = fitted.width, h = fitted.height
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                if let image = phone.preview {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    ProgressView()
                }
                if showClock { clockGuide(in: fitted) }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous).stroke(.secondary.opacity(0.5)))
            Text("\(width) × \(height)" + (options.smooth ? ", smooth" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()   // a caption wider than its preview would shrink, and narrow the gallery too
                .frame(height: Self.captionHeight)
        }
        .onAppear { phone.appear() }
        .onDisappear { phone.disappear() }
    }

    /// Roughly where the Lock Screen puts the date and the time.
    private func clockGuide(in size: CGSize) -> some View {
        // the text follows the height, until a custom size narrower than any iPhone would cut it off
        let h = size.height, textScale = min(h, size.width * 2.2)
        return VStack(spacing: 0) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: textScale * 0.022, weight: .semibold))
                .padding(.top, h * 0.1)
            Text("9:41")
                .font(.system(size: textScale * 0.12, weight: .semibold, design: .rounded))
            Spacer()
        }
        .foregroundStyle(.white.opacity(0.85))
        .allowsHitTesting(false)
    }
}

/// iPhone wallpaper export: a portrait recomposition of the current scene as a still or a
/// Live Photo. Its preview is `PhoneStage`, on the stage.
struct PhoneTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var phone = PhoneExporter.shared
    @Binding var showClock: Bool

    var body: some View {
        Form {
            deviceSection
            lookSection
            exportSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var deviceSection: some View {
        Section {
            Picker("Model", selection: $phone.model) {
                ForEach(PhoneModel.presets) { Text($0.name).tag($0.key) }
                Divider()
                Text("Custom size").tag("custom")
            }
            if phone.model == "custom" {
                LabeledContent("Size in pixels") {
                    HStack {
                        TextField("Width", value: $phone.options.width, format: .number.grouping(.never)).frame(width: 70)
                        Text("×")
                        TextField("Height", value: $phone.options.height, format: .number.grouping(.never)).frame(width: 70)
                    }
                    .labelsHidden()
                }
            } else {
                LabeledContent("Size in pixels", value: "\(phone.options.width) × \(phone.options.height)")
            }
        } header: {
            GroupHeader(title: "iPhone")
        }
    }

    private var lookSection: some View {
        Section {
            Picker("Style", selection: $phone.options.smooth) {
                Text("Dithered").tag(false)
                Text("Smooth").tag(true)
            }
            .pickerStyle(.segmented)
            if !phone.options.smooth {
                Picker("Pixel size", selection: $phone.options.pixelSize) {
                    Text("Auto (\(MobileOptions.autoPixelSize(desktop: store.config.pixelSize)) px)").tag(0)
                    ForEach([2, 3, 4, 5, 6, 8], id: \.self) { Text("\($0) px").tag($0) }
                }
            }
            SliderRow(title: "Zoom", value: $phone.options.framing.zoom, range: 0.6...1.8) { String(format: "%.2f×", $0) }
            SliderRow(title: "Subject height", value: $phone.options.framing.shift, range: -0.25...0.25) {
                String(format: "%+.0f%%", $0 * 100)
            }
            HStack {
                Toggle("Show the Lock Screen clock", isOn: $showClock)
                Spacer()
                Button("Reset Framing") { phone.options.framing = PhoneFraming() }
                    .disabled(phone.options.framing == PhoneFraming())
            }
        } header: {
            GroupHeader(title: "Look")
        } footer: {
            GroupFooter("Uses this scene's settings from the other sections. Events are left out.")
        }
    }

    private var exportSection: some View {
        Section {
            LabeledContent("Still") {
                HStack {
                    Picker("Format", selection: $phone.stillFormat) {
                        Text("PNG").tag(MobileExport.StillFormat.png)
                        Text("HEIC").tag(MobileExport.StillFormat.heic)
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    Button("Save Still…") { phone.saveStill() }
                }
            }
            Picker("Live Photo motion", selection: $phone.options.motionSpeed) {
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
            }
            .help("1× is the desktop's speed. Faster makes the motion show in a short loop.")
            LabeledContent("Live Photo") {
                HStack {
                    Button("Save Files…") { phone.saveLivePhotoFiles() }
                    Button("Add to Photos") { phone.addLivePhotoToPhotos() }
                        .help("Reaches your iPhone through iCloud Photos. You can also AirDrop both files.")
                }
            }
            .help("Press and hold it in Photos to play it.")
            if phone.busy || !phone.status.isEmpty {
                HStack {
                    if phone.busy {
                        if let p = phone.progress { ProgressView(value: p).frame(width: 80) } else { ProgressView().controlSize(.small) }
                    }
                    Text(phone.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            GroupHeader(title: "Export")
        } footer: {
            GroupFooter("The Live Photo is a 3-second loop paired with the still. iOS may show it as a still on the Lock Screen.")
                .help("Orbits are held still in the loop. iOS 17 and later can play Live Photo wallpapers when the Lock Screen wakes, but often shows \"Motion not available\" for ones not taken with the Camera.")
        }
        .disabled(phone.busy)
    }
}
