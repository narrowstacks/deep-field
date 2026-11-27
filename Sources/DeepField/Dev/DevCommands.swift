import Foundation

/// Dev command line. Each command renders offscreen or prints, then exits; without one the app
/// starts normally.
///
///     --snapshot out.png [--size 3440x1440] [--time 10] [--no-events] [--transition-from scene:0.5:pan]
///     --benchmark [--size 3440x1440] [--time 300] [--frames 120] [--no-events]
///     --list-events [minutes]
///     --mobile-export outdir [--device 17-pro-max|WIDTHxHEIGHT] [--live] [--smooth]
///         [--phone-pixel N] [--zoom 1.0] [--shift 0.0] [--speed 2]
///     --check-live still.heic movie.mov     (pairing metadata, and whether it loads as a Live Photo)
///     --fetch-live-earth                    (fetch Live Earth's cloud map and aurora forecast into the cache)
///     --prefetch-history SECONDS --config ... (fetch real past clouds for a frozen moment and the span after it)
///
/// Live Earth renders never fetch, and read the bundled cloud and aurora maps so they come out the
/// same every time; `--live-earth-cache` reads the last fetched ones instead. `--earth-timelapse N` runs its
/// clock N times as fast from its frozen time (or now), for loops that show the day go by.
///
/// Shared options: `--scene <SceneKind>`, `--preset <palette name>`, `--config '<json>'` (overrides
/// any settings), `--defaults` (start from the default settings instead of the saved ones),
/// `--demo id:start,...` (forces event kind `id` to start at `start` seconds).
enum DevCommands {
    static func runIfRequested() {
        let args = Arguments(CommandLine.arguments)
        // --demo also works on a normal launch, so it's applied before looking for a command
        if let demo = args.value("--demo") {
            for pair in demo.split(separator: ",") {
                let parts = pair.split(separator: ":")
                if parts.count == 2, let id = UInt64(parts[0]), let start = Double(parts[1]) {
                    ConfigStore.shared.demoEvents[id] = start
                }
            }
        }
        if let path = args.value("--preset-roundtrip") {
            // dev: write the given config as a .deepfield file, read it back, and check it matches
            let preset = UserPreset(name: "Round Trip", config: args.config())
            guard let data = PresetStore.fileData(for: preset) else { exit(1) }
            try? data.write(to: URL(fileURLWithPath: path))
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let back = PresetStore.preset(from: dict)
            // the file leaves out Live Earth's place
            let ok = back?.config == preset.config.withPlace(of: WallpaperConfig())
            print(ok ? "round trip OK" : "round trip MISMATCH")
            exit(ok ? 0 : 1)
        }
        if let path = args.value("--preset-check") {
            // dev: load a .deepfield file the way Import does and print what it holds
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let p = PresetStore.preset(from: dict) else { print("not a preset"); exit(1) }
            print("\(p.name): scene \(p.config.scene.rawValue), bloom \(p.config.bloom), levels \(p.config.levels)")
            exit(0)
        }
        if args.has("--check-schedule") {
            exit(ScheduleCheck.run() ? 0 : 1)
        }
        if args.has("--check-customization") {
            exit(CustomizationCheck.run() ? 0 : 1)
        }
        if args.has("--fetch-live-earth") {
            exit(LiveEarthFeeds.shared.fetchNow(Renderer.shared.device, Renderer.shared.queue) ? 0 : 1)
        }
        if let n = args.value("--earth-timelapse").flatMap(Double.init) { SceneParams.earthTimeLapse = n }
        if let span = args.value("--prefetch-history").flatMap(Double.init) {
            HistoricalClouds.shared.blocking = true
            // fetch a span's real clouds (from the config's frozen moment) before rendering it in parallel
            let c = args.config()
            let start = SceneParams.liveEarthDate(c)
            let home = Astronomy.point(latitude: c.homeLatitude, longitude: c.homeLongitude)
            guard let source = HistoricalClouds.source(for: start, home: home, distance: c.earthDistance) else {
                print("no past clouds for that moment"); exit(1)
            }
            HistoricalClouds.shared.prefetch(from: start, seconds: span, source: source)
            exit(0)
        }
        guard args.has("--list-events") || args.has("--snapshot") || args.has("--benchmark")
                || args.has("--mobile-export") || args.has("--check-live") else { return }

        LiveEarthFeeds.shared.allowNetwork = false
        LiveEarthFeeds.shared.useCache = args.has("--live-earth-cache")
        // renders of past moments wait for that day's clouds (they don't change, so it stays deterministic)
        HistoricalClouds.shared.blocking = true
        let config = args.config()
        let eventsEnabled = !args.has("--no-events")
        if args.has("--list-events") {
            EventSchedule(seed: 1).list(minutes: args.value("--list-events").flatMap(Double.init) ?? 60, config: config)
            exit(0)
        }
        if let i = args.args.firstIndex(of: "--check-live"), i + 2 < args.args.count {
            MobileExportCommand.check(URL(fileURLWithPath: args.args[i + 1]), URL(fileURLWithPath: args.args[i + 2]))
            exit(0)
        }
        if let out = args.value("--mobile-export") {
            MobileExportCommand.run(out: out, config: config, args: args)
            exit(0)
        }
        let size = args.size()
        if let path = args.value("--snapshot") {
            let time = args.value("--time").flatMap(Double.init) ?? 10
            // --transition-from <scene>:<progress>[:<style>] renders a schedule transition from that scene
            var transition: FrameCapture.Transition?
            if let spec = args.value("--transition-from") {
                let parts = spec.split(separator: ":").map(String.init)
                guard parts.count >= 2, let kind = SceneKind(rawValue: parts[0]), let progress = Double(parts[1]),
                      let style = parts.count > 2 ? TransitionStyle(rawValue: parts[2]) : .dissolve else {
                    FileHandle.standardError.write("--transition-from expects <scene>:<progress>[:<style>]\n".data(using: .utf8)!)
                    exit(1)
                }
                var from = config
                from.scene = kind
                transition = (from, progress, style)
            }
            Snapshot.render(to: path, config: config, size: size, time: time, eventsEnabled: eventsEnabled,
                            transition: transition)
            exit(0)
        }
        if args.has("--benchmark") {
            let scenes = args.has("--scene") ? [config.scene] : SceneKind.listed
            Benchmark.run(config: config, scenes: scenes, size: size,
                          startTime: args.value("--time").flatMap(Double.init) ?? 300,
                          frames: args.value("--frames").flatMap(Int.init) ?? 120,
                          eventsEnabled: eventsEnabled)
            exit(0)
        }
    }
}

struct Arguments {
    let args: [String]
    init(_ args: [String]) { self.args = args }

    func has(_ flag: String) -> Bool { args.contains(flag) }

    func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    /// Output size in screen pixels; defaults to a 3440x1440 ultrawide.
    func size() -> (width: Int, height: Int) {
        let parts = (value("--size") ?? "3440x1440").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else {
            FileHandle.standardError.write("--size expects WIDTHxHEIGHT\n".data(using: .utf8)!)
            exit(1)
        }
        return (parts[0], parts[1])
    }

    /// The saved config (or the defaults, with --defaults) with --scene, --preset and --config applied.
    func config() -> WallpaperConfig {
        var config = has("--defaults") ? WallpaperConfig() : ConfigStore.shared.config
        if let s = value("--scene"), let kind = SceneKind(rawValue: s) { config.scene = kind }
        if let p = value("--preset") {
            if let preset = PaletteConfig.presets.first(where: { $0.0 == p }) { config.palette = preset.1 }
            ColorPreset.all(for: config.scene).first { $0.name == p }?.apply(to: &config)
        }
        if let json = value("--config"), let patch = json.data(using: .utf8),
           let patchDict = try? JSONSerialization.jsonObject(with: patch) as? [String: Any],
           let base = try? JSONEncoder().encode(config),
           var dict = try? JSONSerialization.jsonObject(with: base) as? [String: Any] {
            dict.merge(patchDict) { _, new in new }
            if let merged = try? JSONSerialization.data(withJSONObject: dict),
               let c = WallpaperConfig.decode(merged) { config = c }
        }
        return config
    }
}

extension EventSchedule {
    /// Prints when each event kind (the sky's and each scene's own) fires in the
    /// first `minutes`, at the configured frequencies.
    func list(minutes: Double, config c: WallpaperConfig) {
        let w = c.wormholeEvents.rate, cm = c.cometEvents.rate, st = c.starFlares.rate
        for (name, k, rate) in [("supernova", Self.supernova, c.supernovae.rate), ("comet", Self.comet, c.comets.rate),
                                ("farSupernova", Self.farSupernova, w), ("throatFlare", Self.throatFlare, w),
                                ("infall", Self.infall, w), ("emergence", Self.emergence, w),
                                ("cometOutburst", Self.cometOutburst, cm), ("tailDisconnect", Self.tailDisconnect, cm),
                                ("stellarFlare", Self.stellarFlare, st), ("coronalEjection", Self.coronalEjection, st),
                                ("prominenceEruption", Self.prominenceEruption, st), ("surge", Self.surge, st),
                                ("shellEjection", Self.shellEjection, c.planetaryEvents.rate),
                                ("whiteStorm", Self.whiteStorm, c.ringedEvents.rate),
                                ("substorm", Self.substorm, c.auroraEvents.rate),
                                ("cometImpact", Self.cometImpact, c.gasEvents.rate),
                                ("accretionOutburst", Self.accretionOutburst, c.protoEvents.rate),
                                ("swarmWave", Self.swarmWave, c.dysonEvents.rate),
                                ("starGlint", Self.starGlint, c.rogueEvents.rate),
                                ("eclipseEruption", Self.eclipseEruption, c.eclipseEvents.rate),
                                ("quasarFlare", Self.quasarFlare, c.quasarEvents.rate)] {
            var t = 0.0
            var starts: [Int] = []
            while t < minutes * 60 {
                if let (age, _) = active(k, rate: rate, at: t), age < 1 { starts.append(Int(t)) }
                t += 1
            }
            print(k.id, name, starts)   // the id is what --demo takes
        }
        // the neutron star merger starts each of its scene's cycles rather than being scheduled
        var mergers: [Int] = []
        var t = 0.0
        while t < minutes * 60 {
            if SceneParams.mergerClock(c, t, demo: [:]).u < 1 { mergers.append(Int(t)) }
            t += 1
        }
        print(Self.neutronMerger.id, "neutronMerger", mergers)
        var bbh: [Int] = []
        t = 0
        while t < minutes * 60 {
            if SceneParams.bbhClock(c, t, demo: [:]).u < 1 { bbh.append(Int(t)) }
            t += 1
        }
        print(Self.blackHoleMerger.id, "blackHoleMerger", bbh)
    }
}
