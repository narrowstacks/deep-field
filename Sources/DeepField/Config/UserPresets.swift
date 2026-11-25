import AppKit
import Combine
import UniformTypeIdentifiers

/// A saved customization: everything about the look (scene, its settings, colors, sky, image),
/// but not the machine's own settings (frame rate, lock screen), which stay as they are. Live
/// Earth's place can be someone's own location, so a preset only brings it when asked to.
struct UserPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var config: WallpaperConfig
    /// Whether applying it also moves Live Earth to its place.
    var includesPlace = false

    /// `config` with the machine's own settings taken from `current`.
    func applied(over current: WallpaperConfig) -> WallpaperConfig {
        var c = includesPlace ? config : config.withPlace(of: current)
        c.fps = current.fps
        c.lockScreenStill = current.lockScreenStill
        c.lockScreenSmooth = current.lockScreenSmooth
        c.phoneFraming = nil
        return c.sanitized()
    }

    /// Whether `current` is this preset's look, so the menus show it as the current one.
    func matches(_ current: WallpaperConfig) -> Bool {
        applied(over: current).withOwnImageCurrent == current.withOwnImageCurrent
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

    /// Saves the current settings under `name`, replacing a preset of the same name (which keeps
    /// its place option unless `includePlace` is given).
    @discardableResult
    func saveCurrent(as name: String, includePlace: Bool? = nil) -> UserPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var preset = UserPreset(name: trimmed.isEmpty ? "Untitled" : trimmed, config: ConfigStore.shared.config,
                                includesPlace: includePlace ?? false)
        if let i = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) {
            preset.id = presets[i].id
            preset.includesPlace = includePlace ?? presets[i].includesPlace
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        return preset
    }

    func apply(_ preset: UserPreset) {
        ConfigStore.shared.config = preset.applied(over: ConfigStore.shared.config)
    }

    /// The preset keeps the place it was saved with either way, so this can be switched back.
    func setIncludesPlace(_ on: Bool, for preset: UserPreset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i].includesPlace = on
    }

    func delete(_ preset: UserPreset) { presets.removeAll { $0.id == preset.id } }

    /// False, changing nothing, when the name is empty or another preset has it.
    @discardableResult
    func rename(_ preset: UserPreset, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = presets.firstIndex(where: { $0.id == preset.id }) else { return false }
        if let other = named(trimmed), other.id != preset.id { return false }
        presets[i].name = trimmed
        return true
    }

    /// The preset called `name`, ignoring case and surrounding space.
    func named(_ name: String) -> UserPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// `name`, with a number if a preset already has it.
    private func unusedName(_ base: String) -> String {
        var name = base, n = 2
        while named(name) != nil {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// The preset the current settings match, if any.
    var current: UserPreset? {
        let c = ConfigStore.shared.config
        return presets.first { $0.matches(c) }
    }

    // MARK: files

    /// The file's layout. Written with JSONEncoder, which keeps numbers short (0.334, not
    /// JSONSerialization's 0.33400000000000002), so the file is pleasant to read and edit.
    private struct PresetFile: Encodable {
        let format = "deep-field-preset"
        let version = 1
        let name: String
        let config: WallpaperConfig
        let includesPlace: Bool
    }

    /// Without `includePlace` the file holds the default place. With it, the place is a fixed one:
    /// following the Mac would mean someone else's Mac.
    static func fileData(for preset: UserPreset, includePlace: Bool = false) -> Data? {
        var config = includePlace ? preset.config : preset.config.withPlace(of: WallpaperConfig())
        config.homeFromDevice = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(PresetFile(name: preset.name, config: config, includesPlace: includePlace))
    }

    static func preset(from dict: [String: Any]) -> UserPreset? {
        guard let configObject = dict["config"],
              let data = try? JSONSerialization.data(withJSONObject: configObject),
              var config = WallpaperConfig.decode(data) else { return nil }
        // a file never makes someone else's Mac use its location
        if dict["format"] != nil { config.homeFromDevice = false }
        let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Imported"
        let id = (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return UserPreset(id: id, name: name, config: config, includesPlace: dict["includesPlace"] as? Bool ?? false)
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
        preset.name = unusedName(preset.name)
        presets.append(preset)
        return preset
    }

    // MARK: panels (shared by the menu bar and the Customize window)

    /// Asks for a name, then saves the current settings under it. Asks again before replacing one.
    func promptToSave() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Save the current scene and its look under a name. Frame rate and lock screen settings aren't included."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        field.stringValue = unusedName(ConfigStore.shared.config.scene.title)
        let place = Self.placeCheckbox
        field.frame.origin.y = 28
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        box.addSubview(field)
        box.addSubview(place)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = name.isEmpty ? unusedName("Untitled") : name
            if let existing = named(final), !confirmReplace(existing) { continue }
            saveCurrent(as: final, includePlace: place.state == .on)
            return
        }
    }

    /// Off to start with, since the place can be this Mac's location.
    private static var placeCheckbox: NSButton {
        let box = NSButton(checkboxWithTitle: "Include Live Earth's place", target: nil, action: nil)
        box.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        box.toolTip = "The latitude and longitude Live Earth is centered on, which can be where you are"
        return box
    }

    private func confirmReplace(_ preset: UserPreset) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace \u{201C}\(preset.name)\u{201D}?"
        alert.informativeText = "A preset with this name already exists. Replacing it can't be undone."
        // Cancel is the default button, so pressing Return twice never replaces a preset
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
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
        let place = Self.placeCheckbox
        place.setFrameOrigin(NSPoint(x: 20, y: 10))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        box.addSubview(place)
        panel.accessoryView = box
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = Self.fileData(for: p, includePlace: place.state == .on) else { return }
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
        while alert.runModal() == .alertFirstButtonReturn {
            if rename(preset, to: field.stringValue) { return }
            let problem = NSAlert()
            problem.messageText = "That name can't be used"
            problem.informativeText = named(field.stringValue) == nil
                ? "Enter a name for the preset." : "Another preset already has that name."
            problem.runModal()
        }
    }
}
