import AppIntents
import Foundation

// Focus filters and Shortcuts actions. A Focus filter (System Settings > Focus > a Focus >
// Focus Filters > Deep Field) shows a preset or scene while that Focus is on; the system calls
// `perform()` as the Focus turns on, and again with empty parameters as it turns off. The same
// preset and scene choices are Shortcuts actions, for automations the filter doesn't cover.
// The system reads all of this from Metadata.appintents, which build.sh extracts.

/// The listed scenes, for Focus filters and Shortcuts. Its own type rather than SceneKind, since
/// the hidden nebula scene shouldn't be offered there.
enum SceneChoice: String, AppEnum {
    case blackHole, tidalDisruption, wormhole, binary, trinary, galaxy, pulsar, planetaryNebula, ringedPlanet,
         auroraOrbit, gasGiant, protoplanetaryDisk, neutronMerger, blackHoleMerger, dysonSwarm, roguePlanet,
         eclipse, quasar, comet, stellarSurface

    var kind: SceneKind { SceneKind(rawValue: rawValue) ?? .blackHole }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static var caseDisplayRepresentations: [SceneChoice: DisplayRepresentation] = [
        .blackHole: "Black Hole",
        .tidalDisruption: "Star Meets Black Hole",
        .wormhole: "Wormhole",
        .binary: "Binary Stars",
        .trinary: "Trinary Stars",
        .galaxy: "Galaxy",
        .pulsar: "Pulsar",
        .planetaryNebula: "Planetary Nebula",
        .ringedPlanet: "Ringed Planet",
        .auroraOrbit: "Aurora from Orbit",
        .gasGiant: "Gas Giant Storms",
        .protoplanetaryDisk: "Protoplanetary Disk",
        .neutronMerger: "Neutron Star Merger",
        .blackHoleMerger: "Black Hole Merger",
        .dysonSwarm: "Dyson Swarm",
        .roguePlanet: "Rogue Planet",
        .eclipse: "Eclipse",
        .quasar: "Quasar",
        .comet: "Comet",
        .stellarSurface: "Star Close-up",
    ]
}

/// A saved preset, as Shortcuts and Focus settings list it.
struct PresetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static var defaultQuery = PresetQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ preset: UserPreset) {
        id = preset.id
        name = preset.name
    }
}

struct PresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        await MainActor.run {
            PresetStore.shared.presets.filter { identifiers.contains($0.id) }.map(PresetEntity.init)
        }
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        await MainActor.run { PresetStore.shared.presets.map(PresetEntity.init) }
    }
}

struct DeepFieldFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Set Wallpaper"
    static var description: IntentDescription? = IntentDescription(
        "Shows one of your presets, or a scene, while this Focus is on. Your wallpaper goes back to how it was when the Focus ends.")

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    @Parameter(title: "Scene", description: "Used when no preset is chosen, or to show the preset's look on another scene.")
    var scene: SceneChoice?

    var displayRepresentation: DisplayRepresentation {
        switch (preset, scene) {
        case let (p?, s?): DisplayRepresentation(title: "\(p.name)", subtitle: "\(s.kind.title)")
        case let (p?, nil): DisplayRepresentation(title: "\(p.name)")
        case let (nil, s?): DisplayRepresentation(title: "\(s.kind.title)")
        default: DisplayRepresentation(title: "Choose a preset or scene")
        }
    }

    func perform() async throws -> some IntentResult {
        let presetID = preset?.id, scene = scene?.kind
        await MainActor.run { FocusWallpaper.apply(preset: presetID, scene: scene) }
        return .result()
    }
}

struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Deep Field Preset"
    static var description = IntentDescription("Switches the wallpaper to one of your saved presets.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    func perform() async throws -> some IntentResult {
        let id = preset.id
        await MainActor.run {
            if let p = PresetStore.shared.presets.first(where: { $0.id == id }) { PresetStore.shared.apply(p) }
        }
        return .result()
    }
}

struct SetSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Deep Field Scene"
    static var description = IntentDescription("Switches the wallpaper to a scene, keeping its current settings.")

    @Parameter(title: "Scene")
    var scene: SceneChoice

    func perform() async throws -> some IntentResult {
        let kind = scene.kind
        await MainActor.run { ConfigStore.shared.config.scene = kind }
        return .result()
    }
}

/// What a Focus filter changes, and putting it back. The settings from before the Focus are
/// kept in UserDefaults, so they come back even if the app quit while the Focus was on.
enum FocusWallpaper {
    private static let key = "focusRestoreConfig"

    @MainActor
    static func apply(preset: UUID?, scene: SceneKind?) {
        let store = ConfigStore.shared
        let defaults = UserDefaults.standard
        guard preset != nil || scene != nil else {
            // the Focus ended (or its filter was emptied): put the earlier settings back
            if let data = defaults.data(forKey: key), let saved = WallpaperConfig.decode(data) {
                store.config = UserPreset(name: "", config: saved).applied(over: store.config)
            }
            defaults.removeObject(forKey: key)
            return
        }
        // only the first Focus to change things saves; switching between Focuses keeps it
        if defaults.data(forKey: key) == nil, let data = try? JSONEncoder().encode(store.config) {
            defaults.set(data, forKey: key)
        }
        if let preset, let p = PresetStore.shared.presets.first(where: { $0.id == preset }) {
            PresetStore.shared.apply(p)
        }
        if let scene, scene.isListed { store.config.scene = scene }
    }
}
