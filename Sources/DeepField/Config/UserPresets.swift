import AppKit
import Combine
import UniformTypeIdentifiers

/// A saved customization: everything about the look (scene, its settings, colors, sky, image),
/// but not the machine's own settings (frame rate, lock screen), which stay as they are.
struct UserPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var config: WallpaperConfig

    /// `config` with the machine's own settings taken from `current`.
    func applied(over current: WallpaperConfig) -> WallpaperConfig {
        var c = config
        c.fps = current.fps
        c.lockScreenStill = current.lockScreenStill
        c.lockScreenSmooth = current.lockScreenSmooth
        c.phoneFraming = nil
        return c.sanitized()
    }
}

/// The user's presets, kept in UserDefaults, plus import and export as `.deepfield` files
/// (JSON: `{"format": "deep-field-preset", "version": 1, "name": ..., "config": {...}}`).
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    static let fileExtension = "deepfield"
    static var fileType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json }

    private let key = "userPresets"
    @Published private(set) var presets: [UserPreset] = [] {
        didSet { save() }
    }

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        // decoded one by one through the config's lenient decoder, so a preset saved by an older
        // or newer version still loads (unknown or missing keys fall back to defaults)
        presets = list.compactMap(Self.preset(from:))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: editing

    /// Saves the current settings under `name`, replacing a preset of the same name.
    @discardableResult
    func saveCurrent(as name: String) -> UserPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = UserPreset(name: trimmed.isEmpty ? "Untitled" : trimmed, config: ConfigStore.shared.config)
        if let i = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) {
            presets[i] = UserPreset(id: presets[i].id, name: preset.name, config: preset.config)
        } else {
            presets.append(preset)
        }
        return preset
    }

    func apply(_ preset: UserPreset) {
        ConfigStore.shared.config = preset.applied(over: ConfigStore.shared.config)
    }

    func delete(_ preset: UserPreset) { presets.removeAll { $0.id == preset.id } }

    func rename(_ preset: UserPreset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i].name = trimmed
    }

    /// The preset the current settings match, if any.
    var current: UserPreset? {
        let c = ConfigStore.shared.config
        return presets.first { $0.applied(over: c) == c }
    }

    // MARK: files

    /// The file's layout. Written with JSONEncoder, which keeps numbers short (0.334, not
    /// JSONSerialization's 0.33400000000000002), so the file is pleasant to read and edit.
    private struct PresetFile: Encodable {
        let format = "deep-field-preset"
        let version = 1
        let name: String
        let config: WallpaperConfig
    }

    static func fileData(for preset: UserPreset) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(PresetFile(name: preset.name, config: preset.config))
    }

    static func preset(from dict: [String: Any]) -> UserPreset? {
        guard let configObject = dict["config"],
              let data = try? JSONSerialization.data(withJSONObject: configObject),
              let config = WallpaperConfig.decode(data) else { return nil }
        let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Imported"
        let id = (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return UserPreset(id: id, name: name, config: config)
    }

    /// Reads a `.deepfield` file and adds it (a name already in use gets a number).
    @discardableResult
    func importFile(_ url: URL) throws -> UserPreset {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var preset = Self.preset(from: dict) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        preset.id = UUID()
        var name = preset.name, n = 2
        while presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(preset.name) \(n)"
            n += 1
        }
        preset.name = name
        presets.append(preset)
        return preset
    }

    // MARK: panels (shared by the menu bar and the Customize window)

    /// Asks for a name, then saves the current settings under it.
    func promptToSave() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Save the current scene and its look under a name. Frame rate and lock screen settings aren't included."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        field.stringValue = current?.name ?? ConfigStore.shared.config.scene.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { saveCurrent(as: field.stringValue) }
    }

    func promptToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Deep Field preset files to add."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var failed: [String] = []
        var last: UserPreset?
        for url in panel.urls {
            do { last = try importFile(url) } catch { failed.append(url.lastPathComponent) }
        }
        if panel.urls.count == 1, let last { apply(last) }
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Couldn't import \(failed.joined(separator: ", "))"
            alert.informativeText = "That file isn't a Deep Field preset."
            alert.runModal()
        }
    }

    /// Exports a preset, or the current settings when `preset` is nil.
    func promptToExport(_ preset: UserPreset?) {
        let p = preset ?? UserPreset(name: current?.name ?? ConfigStore.shared.config.scene.title, config: ConfigStore.shared.config)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = "\(p.name).\(Self.fileExtension)"
        panel.message = "Anyone with Deep Field can import this file."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = Self.fileData(for: p) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func confirmDelete(_ preset: UserPreset) {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(preset.name)\u{201D}?"
        alert.informativeText = "Your current settings stay as they are."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { delete(preset) }
    }

    func promptToRename(_ preset: UserPreset) {
        let alert = NSAlert()
        alert.messageText = "Rename Preset"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = preset.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { rename(preset, to: field.stringValue) }
    }
}
