import AppKit
import ServiceManagement

/// What a command prints and its exit status. Built the same way whether the command runs in
/// the app (sent over `CLIServer`'s port) or in the `deepfield` process (the app isn't running).
final class CLIOutput: Codable {
    var out = ""
    var err = ""
    var code: Int32 = 0

    func print(_ s: String) { out += s + "\n" }
    func warn(_ s: String) { err += s + "\n" }
    func fail(_ s: String, code: Int32 = 1) {
        err += "deepfield: \(s)\n"
        self.code = code
    }
}

/// The commands that read or change the wallpaper's state. `inApp` is true inside the running
/// app, where changes show at once (and can transition); otherwise they're saved for its next
/// launch, and commands that need the live wallpaper fail.
struct CLIService {
    let cwd: String
    let inApp: Bool
    let o = CLIOutput()

    static func run(_ argv: [String], cwd: String, inApp: Bool) -> CLIOutput {
        let s = CLIService(cwd: cwd, inApp: inApp)
        do {
            try s.dispatch(argv)
        } catch let e as CLIError {
            s.o.fail(e.message)
        } catch {
            s.o.fail(error.localizedDescription)
        }
        return s.o
    }

    private var store: ConfigStore { .shared }
    private var delegate: AppDelegate? { inApp ? NSApp.delegate as? AppDelegate : nil }

    private func dispatch(_ argv: [String]) throws {
        guard let name = argv.first else { return }
        let rest = Array(argv.dropFirst())
        switch name {
        case "status": try status(rest)
        case "get": try get(rest)
        case "set": try set(rest)
        case "scene": try scene(rest)
        case "reset": try reset(rest)
        case "keys": try keys(rest)
        case "scenes": try scenes(rest)
        case "presets": try presets(rest)
        case "preset": try preset(rest)
        case "events": try events(rest)
        case "event": try event(rest)
        case "on": try wallpaper(rest, on: true)
        case "off": try wallpaper(rest, on: false)
        case "toggle": try wallpaper(rest, on: !Settings.wallpaperEnabled)
        case "pause": try pause(rest, true)
        case "resume": try pause(rest, false)
        case "schedule": try schedule(rest)
        case "login": try login(rest)
        case "customize": try customize(rest)
        case "quit": try quit(rest)
        default: throw CLIError("unknown command \(name)")
        }
    }

    private func requireApp(_ what: String) throws {
        guard inApp else { throw CLIError("Deep Field isn't running, so there's nothing to \(what). Start it with `deepfield launch`.") }
    }

    private func savedNote() {
        if !inApp { o.warn("Deep Field isn't running; saved for its next launch.") }
    }

    // MARK: applying changes

    private static let changeValues: Set<String> = ["--fade", "--style", "--preset"]

    /// Shows `new`: transitions over `--fade` seconds in the running app, or cuts.
    private func commit(_ new: WallpaperConfig, _ a: ParsedArgs) throws {
        let fade = try a.double("--fade") ?? 0
        var style = TransitionStyle.dissolve
        if let s = a.value("--style") {
            guard let t = TransitionStyle.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) else {
                throw CLIError("no transition style \u{201C}\(s)\u{201D} (choose from \(TransitionStyle.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            style = t
        }
        if inApp && fade > 0 {
            store.transition(to: new, seconds: fade, style: style)
        } else {
            store.config = new
            if !inApp { store.flush() }
        }
        savedNote()
    }

    private func applyChanges(_ assignments: [String], preset: String?, to base: WallpaperConfig) throws -> WallpaperConfig {
        var c = base
        if let preset { try PresetLookup.apply(preset, to: &c, cwd: cwd) }
        let (new, warnings) = try ConfigKeys.apply(try ConfigKeys.assignments(assignments), to: c)
        warnings.forEach { o.warn("note: \($0)") }
        return new
    }

    // MARK: status

    private func status(_ args: [String]) throws {
        let a = try ParsedArgs(args, flags: ["--json"])
        let c = store.config
        let schedule = ScheduleStore.shared.schedule
        let next = schedule.enabled ? schedule.slot(at: Date())?.next : nil
        var info: [String: Any] = [
            "running": inApp,
            "version": CLI.version,
            "scene": c.scene.rawValue,
            "sceneTitle": c.scene.title,
            "wallpaper": Settings.wallpaperEnabled,
            "schedule": schedule.enabled,
            "focusFilter": UserDefaults.standard.data(forKey: "focusRestoreConfig") != nil,
            "lockScreenStill": c.lockScreenStill,
        ]
        if let p = PresetStore.shared.current { info["preset"] = p.name }
        if let d = delegate { info["paused"] = d.animationPaused }
        if let next { info["nextScheduledChange"] = ISO8601DateFormatter().string(from: next) }
        if a.has("--json") { o.print(ConfigKeys.json(info, pretty: true)); return }
        o.print("Deep Field \(CLI.version), \(inApp ? "running" : "not running")")
        o.print("Scene:      \(c.scene.title) (\(c.scene.rawValue))")
        if let p = info["preset"] as? String { o.print("Preset:     \(p)") }
        var desktop = Settings.wallpaperEnabled ? "shown" : "hidden"
        if delegate?.animationPaused == true { desktop += ", paused" }
        o.print("Desktop:    \(desktop)")
        var sched = schedule.enabled ? "on (\(schedule.mode == .rotate ? "rotating" : "timed"), \(schedule.entries.count) entries)" : "off"
        if let next { sched += ", next change \(DateFormatter.localizedString(from: next, dateStyle: .none, timeStyle: .short))" }
        o.print("Schedule:   \(sched)")
        if info["focusFilter"] as? Bool == true { o.print("Focus:      a Focus filter is choosing the wallpaper") }
        o.print("Lock screen still: \(c.lockScreenStill ? "on" : "off")")
    }

    // MARK: settings

    private func get(_ args: [String]) throws {
        let a = try ParsedArgs(args, flags: ["--json", "--raw"])
        let dict = ConfigKeys.object(store.config)
        if a.has("--raw") {
            // everything, per-scene image settings included (for `render`)
            o.print(ConfigKeys.json(dict, pretty: false))
            return
        }
        if a.positional.isEmpty {
            var shown = dict
            ConfigKeys.internalKeys.forEach { shown[$0] = nil }
            o.print(ConfigKeys.json(shown, pretty: true))
            return
        }
        let paths = ConfigKeys.allPaths(store.config)
        var values: [String: Any] = [:]
        for key in a.positional {
            guard let v = ConfigKeys.value(at: key.split(separator: ".").map(String.init), in: dict) else {
                let near = ConfigKeys.suggestions(for: key, in: paths)
                throw CLIError("unknown setting \u{201C}\(key)\u{201D}" + (near.isEmpty ? "" : " (did you mean \(near.joined(separator: ", "))?)"))
            }
            values[key] = v
        }
        if a.has("--json") {
            o.print(ConfigKeys.json(a.positional.count == 1 ? values[a.positional[0]]! : values, pretty: true))
        } else if a.positional.count == 1 {
            o.print(ConfigKeys.display(values[a.positional[0]]!))
        } else {
            for key in a.positional { o.print("\(key) = \(ConfigKeys.display(values[key]!))") }
        }
    }

    private func set(_ args: [String]) throws {
        let a = try ParsedArgs(args, values: Self.changeValues)
        guard !a.positional.isEmpty || a.value("--preset") != nil else { throw CLIError("usage: deepfield set KEY=VALUE...") }
        let new = try applyChanges(a.positional, preset: a.value("--preset"), to: store.config)
        try commit(new, a)
    }

    private func scene(_ args: [String]) throws {
        let a = try ParsedArgs(args, values: Self.changeValues)
        guard let name = a.positional.first else {
            o.print(store.config.scene.rawValue)
            return
        }
        var c = store.config
        c.scene = try SceneKind.named(name, current: c.scene)
        let new = try applyChanges(Array(a.positional.dropFirst()), preset: a.value("--preset"), to: c)
        try commit(new, a)
        o.print(new.scene.title)
    }

    private func reset(_ args: [String]) throws {
        let a = try ParsedArgs(args, values: ["--fade", "--style", "--scene"], flags: ["--all"])
        let c = store.config
        var new: WallpaperConfig
        if a.has("--all") {
            new = UserPreset(name: "", config: WallpaperConfig(), includesPlace: true).applied(over: c)
        } else if !a.positional.isEmpty {
            let defaults = ConfigKeys.object(WallpaperConfig())
            let list = try a.positional.map { key -> ConfigKeys.Assignment in
                guard let v = ConfigKeys.value(at: key.split(separator: ".").map(String.init), in: defaults) else {
                    throw CLIError("unknown setting \u{201C}\(key)\u{201D}")
                }
                return ConfigKeys.Assignment(key: key, raw: ConfigKeys.isColor(v) ? ConfigKeys.display(v) : ConfigKeys.json(v, pretty: false))
            }
            new = try ConfigKeys.apply(list, to: c).config
        } else {
            let kind = try a.value("--scene").map { try SceneKind.named($0) } ?? c.scene
            new = c.resettingScene(kind)
        }
        try commit(new, a)
    }

    private func keys(_ args: [String]) throws {
        let a = try ParsedArgs(args, values: ["--scene"], flags: ["--all", "--names", "--json"])
        var c = store.config
        let list: [String]
        if a.has("--all") {
            list = ConfigKeys.allPaths(c)
        } else {
            // switched to, for the tilt and image settings that scene has
            if let name = a.value("--scene") { c.scene = try SceneKind.named(name, listedOnly: false) }
            list = WallpaperConfig.sceneKeys(c.scene) + ConfigKeys.imageKeys
        }
        let dict = ConfigKeys.object(c)
        if a.has("--names") { list.forEach { o.print($0) }; return }
        let rows = list.compactMap { key -> (String, String, String)? in
            guard let v = ConfigKeys.value(at: key.split(separator: ".").map(String.init), in: dict) else { return nil }
            let kind: String
            if let choices = ConfigKeys.choices(for: key) { kind = choices.joined(separator: "|") }
            else if ConfigKeys.isColor(v) { kind = "color" }
            else if ConfigKeys.isBool(v) { kind = "bool" }
            else if v is NSNumber { kind = "number" }
            else if v is String { kind = "text" }
            else { kind = "json" }
            return (key, ConfigKeys.display(v), kind)
        }
        if a.has("--json") {
            o.print(ConfigKeys.json(rows.map { ["key": $0.0, "value": $0.1, "type": $0.2] }, pretty: true))
            return
        }
        let w0 = rows.map(\.0.count).max() ?? 0, w1 = min(rows.map(\.1.count).max() ?? 0, 28)
        for (k, v, t) in rows {
            o.print(k.padding(toLength: w0 + 2, withPad: " ", startingAt: 0)
                    + v.padding(toLength: max(w1, v.count) + 2, withPad: " ", startingAt: 0) + t)
        }
    }

    // MARK: lists

    private func scenes(_ args: [String]) throws {
        let a = try ParsedArgs(args, flags: ["--names", "--json"])
        let current = store.config.scene
        if a.has("--names") { SceneKind.listed.forEach { o.print($0.rawValue) }; return }
        if a.has("--json") {
            o.print(ConfigKeys.json(SceneKind.listed.map { ["id": $0.rawValue, "title": $0.title, "current": $0 == current] }, pretty: true))
            return
        }
        let w = SceneKind.listed.map(\.rawValue.count).max() ?? 0
        for k in SceneKind.listed {
            o.print("\(k == current ? "*" : " ") \(k.rawValue.padding(toLength: w + 2, withPad: " ", startingAt: 0))\(k.title)")
        }
    }

    private func presets(_ args: [String]) throws {
        let a = try ParsedArgs(args, values: ["--scene"], flags: ["--names", "--json"])
        let kind = try a.value("--scene").map { try SceneKind.named($0) } ?? store.config.scene
        let user = PresetStore.shared.presets.map(\.name)
        let palettes = PaletteConfig.presets.map(\.0)
        let colors = ColorPreset.all(for: kind).map(\.name)
        if a.has("--names") { (user + colors + palettes).forEach { o.print($0) }; return }
        if a.has("--json") {
            o.print(ConfigKeys.json(["saved": user, "scene": colors, "palette": palettes, "current": PresetStore.shared.current?.name ?? NSNull()], pretty: true))
            return
        }
        let current = PresetStore.shared.current?.name
        o.print("Saved presets:")
        if user.isEmpty { o.print("  (none yet: `deepfield preset save NAME`)") }
        user.forEach { o.print("\($0 == current ? "* " : "  ")\($0)") }
        if !colors.isEmpty {
            o.print("\(kind.title) colors:")
            colors.forEach { o.print("  \($0)") }
        }
        o.print("Palettes (disk, wormhole and star colors):")
        palettes.forEach { o.print("  \($0)") }
    }

    private func preset(_ args: [String]) throws {
        guard let sub = args.first else { throw CLIError("usage: deepfield preset apply|save|delete|rename|export|import ...") }
        let a = try ParsedArgs(Array(args.dropFirst()), values: ["--fade", "--style", "--name"], flags: ["--with-place"])
        let p = a.positional
        let presetStore = PresetStore.shared
        func find(_ name: String) throws -> UserPreset {
            guard let x = presetStore.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw CLIError("no saved preset called \u{201C}\(name)\u{201D}")
            }
            return x
        }
        switch sub {
        case "apply":
            guard let name = p.first else { throw CLIError("usage: deepfield preset apply NAME|FILE [KEY=VALUE...]") }
            try commit(try applyChanges(Array(p.dropFirst()), preset: name, to: store.config), a)
        case "save":
            guard let name = p.first else { throw CLIError("usage: deepfield preset save NAME") }
            let saved = presetStore.saveCurrent(as: name, includePlace: a.has("--with-place") ? true : nil)
            o.print("Saved \u{201C}\(saved.name)\u{201D}")
        case "delete":
            guard let name = p.first else { throw CLIError("usage: deepfield preset delete NAME") }
            presetStore.delete(try find(name))
        case "rename":
            guard p.count == 2 else { throw CLIError("usage: deepfield preset rename OLD NEW") }
            guard presetStore.rename(try find(p[0]), to: p[1]) else {
                throw CLIError("can't rename to \u{201C}\(p[1])\u{201D}: the name is empty or another preset has it")
            }
        case "export":
            // export [NAME] FILE: a saved preset, or the current settings
            guard let path = p.last else { throw CLIError("usage: deepfield preset export [NAME] FILE.deepfield") }
            let preset = p.count >= 2 ? try find(p[0])
                : UserPreset(name: a.value("--name") ?? presetStore.current?.name ?? store.config.scene.title, config: store.config)
            var url = URL(fileURLWithPath: PresetLookup.resolve(path, cwd: cwd))
            if url.pathExtension.isEmpty { url.appendPathExtension(PresetStore.fileExtension) }
            guard let data = PresetStore.fileData(for: preset, includePlace: a.has("--with-place")) else { throw CLIError("couldn't encode the preset") }
            try data.write(to: url, options: .atomic)
            o.print(url.path)
        case "import":
            guard !p.isEmpty else { throw CLIError("usage: deepfield preset import FILE...") }
            for path in p {
                let added = try presetStore.importFile(URL(fileURLWithPath: PresetLookup.resolve(path, cwd: cwd)))
                o.print("Imported \u{201C}\(added.name)\u{201D}")
            }
        default:
            throw CLIError("unknown preset command \(sub) (apply, save, delete, rename, export, import)")
        }
    }

    // MARK: events

    private func events(_ args: [String]) throws {
        let a = try ParsedArgs(args, flags: ["--names", "--json", "--all"])
        let current = store.config.scene
        let list = EventSchedule.named.filter {
            a.has("--all") || a.has("--names") || $0.scene == current || ($0.scene == nil && !current.drawsRealSky)
        }
        if a.has("--names") { list.forEach { o.print($0.name) }; return }
        if a.has("--json") {
            o.print(ConfigKeys.json(list.map { ["name": $0.name, "id": Int($0.kind.id), "scene": $0.scene?.rawValue ?? "sky"] }, pretty: true))
            return
        }
        let w = list.map(\.name.count).max() ?? 0
        for e in list {
            o.print("\(e.name.padding(toLength: w + 2, withPad: " ", startingAt: 0))\(String(e.kind.id).padding(toLength: 4, withPad: " ", startingAt: 0))\(e.scene?.title ?? "sky (shared)")")
        }
        if !a.has("--all") {
            o.print(list.isEmpty ? "(none in \(current.title); --all lists every scene's)"
                                 : "(this scene's and the sky's; --all lists every scene's)")
        }
    }

    private func event(_ args: [String]) throws {
        let a = try ParsedArgs(args)
        guard let name = a.positional.first else { throw CLIError("usage: deepfield event NAME|ID (`deepfield events` lists them)") }
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard let e = EventSchedule.named.first(where: { norm($0.name) == norm(name) || String($0.kind.id) == name }) else {
            throw CLIError("no event called \u{201C}\(name)\u{201D}; `deepfield events --all` lists them")
        }
        try requireApp("show")
        if let reason = EventSchedule.realSkyReason(e, in: store.config.scene) { throw CLIError(reason) }
        if let reason = store.hiddenReason(e.kind) { throw CLIError(reason) }
        if let s = e.scene, s != store.config.scene {
            o.warn("note: \(e.name) happens in \(s.title); switch with `deepfield scene \(s.rawValue)` to see it")
        }
        store.demo(e.kind)
    }

    // MARK: app state

    private func wallpaper(_ args: [String], on: Bool) throws {
        _ = try ParsedArgs(args)
        if let d = delegate { d.setWallpaper(on) } else { Settings.wallpaperEnabled = on; savedNote() }
        o.print(on ? "Shown on the desktop" : "Hidden from the desktop")
    }

    private func pause(_ args: [String], _ paused: Bool) throws {
        _ = try ParsedArgs(args)
        try requireApp(paused ? "pause" : "resume")
        delegate?.animationPaused = paused
    }

    private func schedule(_ args: [String]) throws {
        let a = try ParsedArgs(args, flags: ["--json"])
        let st = ScheduleStore.shared
        switch a.positional.first ?? "status" {
        case "on", "off":
            guard !st.schedule.entries.isEmpty else { throw CLIError("nothing is scheduled yet; set it up in Customize > Schedule") }
            st.schedule.enabled = a.positional[0] == "on"
            savedNote()
        case "next", "skip":
            guard st.schedule.enabled, st.schedule.mode == .rotate, st.schedule.entries.count > 1 else {
                throw CLIError("skipping ahead needs a rotating schedule with more than one entry, turned on")
            }
            Scheduler.shared.skip()
            savedNote()
        case "status":
            let s = st.schedule
            let next = s.enabled ? s.slot(at: Date())?.next : nil
            if a.has("--json") {
                var info: [String: Any] = ["enabled": s.enabled, "mode": s.mode == .rotate ? "rotate" : "timed",
                                           "entries": s.entries.count, "fadeSeconds": s.fadeSeconds, "transition": s.transition.rawValue]
                if let next { info["next"] = ISO8601DateFormatter().string(from: next) }
                o.print(ConfigKeys.json(info, pretty: true))
                return
            }
            o.print("Schedule \(s.enabled ? "on" : "off"): \(s.mode == .rotate ? "rotating" : "timed"), \(s.entries.count) entries, \(s.transition.title.lowercased()) over \(ConfigKeys.number(s.fadeSeconds)) s")
            if let next { o.print("Next change at \(DateFormatter.localizedString(from: next, dateStyle: .short, timeStyle: .short))") }
        default:
            throw CLIError("usage: deepfield schedule [status|on|off|next]")
        }
    }

    private func login(_ args: [String]) throws {
        let a = try ParsedArgs(args)
        let service = SMAppService.mainApp
        switch a.positional.first ?? "status" {
        case "on": try service.register()
        case "off": try service.unregister()
        case "status": break
        default: throw CLIError("usage: deepfield login [status|on|off]")
        }
        switch service.status {
        case .enabled: o.print("Launches at login")
        case .requiresApproval: o.print("Waiting for approval in System Settings > General > Login Items")
        default: o.print("Doesn't launch at login")
        }
    }

    private func customize(_ args: [String]) throws {
        let a = try ParsedArgs(args, values: ["--section"])
        try requireApp("open")
        if let name = a.value("--section") {
            guard let section = CustomizeSection.allCases.first(where: { "\($0)".caseInsensitiveCompare(name) == .orderedSame }) else {
                throw CLIError("no section \u{201C}\(name)\u{201D} (choose from \(CustomizeSection.allCases.map { "\($0)" }.joined(separator: ", ")))")
            }
            CustomizeWindowController.shared.show(section: section)
        } else {
            CustomizeWindowController.shared.show()
        }
    }

    private func quit(_ args: [String]) throws {
        _ = try ParsedArgs(args)
        guard inApp else { o.print("Deep Field isn't running"); return }
        // after the reply is on its way
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }
}
