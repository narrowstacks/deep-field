import SwiftUI

struct SystemTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var lockScreen = LockScreenStill.shared
    @State private var confirmReset = false
    @State private var displayRates = NSScreen.screens.map(\.maximumFramesPerSecond)
    @AppStorage(Settings.dockWhileCustomizingKey) private var dockWhileCustomizing = false

    private var rates: [Int] { FrameRate.choices(displays: displayRates, current: store.config.fps) }

    private var ratePicker: some View {
        Picker("Frame rate", selection: $store.config.fps) {
            ForEach(rates, id: \.self) { Text("\($0) fps").tag($0) }
        }
    }

    var body: some View {
        Form {
            Section {
                // the row has room for the usual rates' segments and no more
                Group {
                    if rates.count > FrameRate.standard.count {
                        ratePicker.pickerStyle(.menu)
                    } else {
                        ratePicker.pickerStyle(.segmented)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    displayRates = NSScreen.screens.map(\.maximumFramesPerSecond)
                }
            } header: {
                GroupHeader(title: "Performance")
            } footer: {
                GroupFooter("Rendering pauses when the desktop is covered or the display sleeps. Low Power Mode limits it to 12 fps. Higher rates use more power.")
                    .help("Larger pixels and lower frame rates use less power.")
            }
            Section {
                Toggle("Use a still of this scene for the lock screen", isOn: $store.config.lockScreenStill)
                if store.config.lockScreenStill {
                    Picker("Style", selection: $store.config.lockScreenSmooth) {
                        Text("Dithered").tag(false)
                        Text("Smooth").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Dithered like the wallpaper, or smooth full color")
                    LabeledContent {
                        Button("Set Now") { lockScreen.setNow() }.disabled(lockScreen.busy)
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
                Toggle("Show in the Dock while customizing", isOn: $dockWhileCustomizing)
                    .onChange(of: dockWhileCustomizing) { _, _ in CustomizeWindowController.shared.updateDockIcon() }
            } header: {
                GroupHeader(title: "Dock")
            } footer: {
                GroupFooter("Deep Field lives in the menu bar. With this on, it also shows in the Dock and the app switcher, with its own menus, while this window is open.")
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset every setting to its default?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { store.config = WallpaperConfig() }
                    }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
