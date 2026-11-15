import SwiftUI

struct SystemTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var lockScreen = LockScreenStill.shared
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Frame rate", selection: $store.config.fps) {
                    ForEach([12, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                GroupHeader(title: "Performance")
            } footer: {
                GroupFooter("Rendering stops whenever the desktop is fully covered or the display sleeps. Low Power Mode caps it at 12 fps. Larger pixels and lower frame rates use less power.")
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
                GroupHeader(title: "Lock Screen")
            } footer: {
                GroupFooter("The lock and login screens show the desktop picture, not the animation. Turning this off puts your own picture back.")
            }
            Section {
                Button("Reset everything to defaults", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset every setting to its default?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { store.config = WallpaperConfig() }
                    }
            } header: {
                GroupHeader(title: "Reset")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
