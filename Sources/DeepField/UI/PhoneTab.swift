import SwiftUI

/// The phone preview on the stage while the Phone section is selected, in place of the
/// landscape one. It owns the exporter's preview lifecycle.
struct PhoneStage: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var phone = PhoneExporter.shared
    let showClock: Bool

    private static let box = CGSize(width: 394, height: 676)

    var body: some View {
        let options = phone.options
        let aspect = CGFloat(options.width) / CGFloat(max(options.height, 1))
        let h = min(Self.box.height, Self.box.width / aspect), w = h * aspect
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                if let image = phone.preview {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    ProgressView()
                }
                if showClock { clockGuide(height: h) }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous).stroke(.secondary.opacity(0.5)))
            Text("\(options.width) × \(options.height)" + (options.smooth ? ", smooth" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 30)
        }
        .onAppear { phone.appear() }
        .onDisappear { phone.disappear() }
    }

    /// Roughly where the Lock Screen puts the date and the time.
    private func clockGuide(height h: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: h * 0.022, weight: .semibold))
                .padding(.top, h * 0.1)
            Text("9:41")
                .font(.system(size: h * 0.12, weight: .semibold, design: .rounded))
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
                Button("Reset framing") { phone.options.framing = PhoneFraming() }
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
                Text("1× (as on the desktop)").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
            }
            LabeledContent("Live Photo") {
                HStack {
                    Button("Save Files…") { phone.saveLivePhotoFiles() }
                    Button("Add to Photos") { phone.addLivePhotoToPhotos() }
                }
            }
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
            GroupFooter("The Live Photo is a 3-second loop with orbits held still, paired with the still; press and hold it in Photos to play it. iOS 17 and later can play Live Photo wallpapers on the Lock Screen when it wakes, but often shows \"Motion not available\" for ones not taken with the Camera, so expect a still wallpaper there. Add to Photos reaches your iPhone through iCloud Photos; or AirDrop both files together.")
        }
        .disabled(phone.busy)
    }
}
