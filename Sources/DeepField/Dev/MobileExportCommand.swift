import AppKit

/// `--mobile-export outdir`: the Mobile tab's exports without the UI. Always writes the portrait
/// still as `<name>.png` (deterministic for a given config and device). With `--live` it also
/// writes the Live Photo pair (`<name>.HEIC` + `<name>.MOV`, with a fresh identifier each run),
/// prints its pairing metadata, checks it loads as a Live Photo (without touching the Photos
/// library), and writes `<name> preview.mp4`, the loop played three times.
enum MobileExportCommand {
    static func run(out: String, config: WallpaperConfig, args: Arguments) {
        var o = MobileOptions()
        let device = args.value("--device") ?? PhoneModel.presets[0].key
        if let model = PhoneModel.presets.first(where: { $0.key == device }) {
            o.width = model.width; o.height = model.height
        } else {
            let parts = device.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else {
                fail("--device expects one of \(PhoneModel.presets.map(\.key).joined(separator: ", ")) or WIDTHxHEIGHT")
            }
            o.width = parts[0]; o.height = parts[1]
        }
        o.smooth = args.has("--smooth")
        o.pixelSize = args.value("--phone-pixel").flatMap(Int.init) ?? 0
        o.framing.zoom = args.value("--zoom").flatMap(Double.init) ?? 1
        o.framing.shift = args.value("--shift").flatMap(Double.init) ?? 0
        o.motionSpeed = args.value("--speed").flatMap(Double.init) ?? o.motionSpeed

        let plan = MobileExport.plan(config, o)
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        let name = MobileExport.baseName(plan)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let still = MobileExport.renderStill(plan) else { fail("rendering failed") }
            let png = folder.appendingPathComponent(name + ".png")
            try MobileExport.writeStill(still, to: png, format: .png)
            print("\(png.path) (\(plan.width)x\(plan.height), shaded \(plan.shadedWidth)x\(plan.shadedHeight), cells \(plan.factor) px)")
            guard args.has("--live") else { return }

            let t0 = CFAbsoluteTimeGetCurrent()
            let files = try MobileExport.writeLivePhoto(plan, folder: folder, baseName: name)
            print("\(files.still.path)\n\(files.movie.path) (\(plan.loop.frames) frames, \(plan.loop.duration) s at \(plan.loop.speed)x, in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms)")
            print("asset identifier: \(files.assetIdentifier)")
            check(files.still, files.movie)

            let preview = folder.appendingPathComponent(name + " preview.mp4")
            try MobileExport.writeMovie(plan, to: preview, assetIdentifier: nil, repeats: 3)
            print(preview.path)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Prints the pair's metadata and whether PhotoKit loads it as a Live Photo (no library access).
    static func check(_ still: URL, _ movie: URL) {
        print(LivePhotoLibrary.inspect(still, movie))
        var result: String??
        LivePhotoLibrary.validate(still, movie) { result = .some($0) }
        let deadline = Date(timeIntervalSinceNow: 30)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        switch result {
        case .some(.none): print("PHLivePhoto: loaded as a Live Photo")
        case .some(.some(let error)): print("PHLivePhoto: failed: \(error)")
        case .none: print("PHLivePhoto: no answer within 30 s")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
