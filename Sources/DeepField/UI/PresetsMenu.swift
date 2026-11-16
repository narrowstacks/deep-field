import SwiftUI

/// The Customize window's Presets menu: apply a saved preset, save the current settings,
/// import and export `.deepfield` files, rename or delete.
struct PresetsMenu: View {
    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        let current = presets.current
        Menu {
            if presets.presets.isEmpty {
                Text("No saved presets yet")
            } else {
                ForEach(presets.presets) { preset in
                    Button { presets.apply(preset) } label: {
                        if preset.id == current?.id {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }
            Divider()
            Button("Save Current Settings as Preset…") { presets.promptToSave() }
            Button("Import Preset…") { presets.promptToImport() }
            Menu("Export") {
                Button("Current Settings…") { presets.promptToExport(nil) }
                if !presets.presets.isEmpty {
                    Divider()
                    ForEach(presets.presets) { p in Button("\(p.name)…") { presets.promptToExport(p) } }
                }
            }
            if !presets.presets.isEmpty {
                Menu("Rename") {
                    ForEach(presets.presets) { p in Button("\(p.name)…") { presets.promptToRename(p) } }
                }
                Menu("Delete") {
                    ForEach(presets.presets) { p in Button("\(p.name)…") { presets.confirmDelete(p) } }
                }
            }
        } label: {
            Label(current?.name ?? "Presets", systemImage: "square.stack")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save, apply, import and export your customizations")
    }
}
