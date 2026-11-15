import SwiftUI

struct DisplayTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var lockScreen = LockScreenStill.shared

    var body: some View {
        Form {
            Section("Pixels") {
                Picker("Pixel size", selection: $store.config.pixelSize) {
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text("\($0) px").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Color levels per channel", selection: $store.config.levels) {
                    ForEach([2, 3, 4, 5, 6, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Dither pattern", selection: $store.config.dither) {
                    ForEach(DitherPattern.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Frame rate", selection: $store.config.fps) {
                    ForEach([12, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Performance")
            } footer: {
                Text("Rendering stops whenever the desktop is fully covered or the display sleeps. Low Power Mode caps it at 12 fps. Larger pixels and lower frame rates use less power.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Use a still of this scene for the lock screen", isOn: $store.config.lockScreenStill)
                if store.config.lockScreenStill {
                    Picker("Style", selection: $store.config.lockScreenSmooth) {
                        Text("Dithered, like the wallpaper").tag(false)
                        Text("Smooth full color").tag(true)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent {
                        Button("Set now") { lockScreen.setNow() }.disabled(lockScreen.busy)
                    } label: {
                        Text(lockScreen.busy ? "Rendering…" : lockScreen.status).foregroundStyle(.secondary)
                    }
                } else if !lockScreen.status.isEmpty {
                    Text(lockScreen.status).foregroundStyle(.secondary)
                }
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("The lock and login screens show the desktop picture, not the animation. Turning this off puts your own picture back.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset everything to defaults", role: .destructive) { store.config = WallpaperConfig() }
            }
        }
        .formStyle(.grouped)
    }
}
