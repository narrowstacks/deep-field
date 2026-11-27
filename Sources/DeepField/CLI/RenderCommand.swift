import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// `deepfield render`: stills, videos, time-lapses, GIFs and PNG sequences, rendered offscreen in
/// this process from the saved settings (or the defaults) plus any changes. Renders are
/// deterministic: events use the same seed as the wallpaper, and nothing is fetched.
enum RenderCommand {
    static let usage = """
        deepfield render [image|video|timelapse] OUT [KEY=VALUE...] [options]

        The extension of OUT picks the format: .png .jpg .heic .tiff for a still, .mp4 .mov for
        video, .gif for an animated GIF, and a folder (ending in /) for numbered PNG frames.
        Starts from the current wallpaper's settings; KEY=VALUE changes them for this render only.

        Look:
          --scene NAME          a scene other than the current one
          --preset NAME|FILE    a saved preset, palette, scene color preset or .deepfield file
          --defaults            start from the default settings instead of yours
          --config JSON         settings as a JSON object
          --smooth              full color at full resolution, without the pixel look
          --no-events           no supernovae or comets in the sky (scene events still happen)
          --demo NAME:SECONDS   start an event at that scene time (repeatable, comma-separated)
        Frame:
          --size WIDTHxHEIGHT   output size (default: your main display's pixels)
          --scale N             multiply the size (0.5 for half size)
          --time SECONDS        scene time of a still, or where a video starts (default: a good moment)
        Motion:
          --duration SECONDS    video length (default 10)
          --fps N               frames per second (default: the wallpaper's, 24)
          --speed N             scene seconds per video second (default 1; timelapse: 60)
          --loop[=SECONDS]      blend the last second (or SECONDS) into the start, for a seamless loop
          --codec h264|hevc|prores   default h264 for .mp4, hevc for .mov
          --bitrate MBPS        video bit rate
        Output:
          --open                open the result when it's done
          --quiet               no progress

        Examples:
          deepfield render shot.png
          deepfield render image galaxy.heic --scene galaxy --size 5120x2880 galaxyType=barred
          deepfield render video loop.mp4 --duration 8 --loop
          deepfield render timelapse earth.mp4 --scene liveEarth --speed 3600 --duration 12
          deepfield render frames/ --duration 2 --fps 12
        Live Earth's day runs at --speed too, so --speed 3600 shows an hour a second.
        """

    private static let stillTypes: [String: UTType] = ["png": .png, "jpg": .jpeg, "jpeg": .jpeg, "heic": .heic,
                                                       "tif": .tiff, "tiff": .tiff]

    /// The render command's options, parsed (also used by `--check-customization`).
    static func arguments(_ argv: [String]) throws -> ParsedArgs {
        try ParsedArgs(argv,
                       values: ["--scene", "--preset", "--config", "--demo", "--size", "--scale", "--time",
                                "--duration", "--fps", "--speed", "--codec", "--bitrate"],
                       flags: ["--defaults", "--smooth", "--no-events", "--open", "--quiet", "--loop"])
    }

    static func run(_ argv: [String], cwd: String) throws -> Int32 {
        let a = try arguments(argv)
        var positional = a.positional
        var mode = "auto"
        if let first = positional.first, ["image", "still", "video", "timelapse", "gif", "frames"].contains(first) {
            mode = first
            positional.removeFirst()
        }
        guard let outArg = positional.first else { throw CLIError("usage: deepfield render [image|video|timelapse] OUT [options]") }
        let out = PresetLookup.resolve(outArg, cwd: cwd)
        let assignments = Array(positional.dropFirst())

        // where the output goes decides the format
        var isDir: ObjCBool = false
        let folder = outArg.hasSuffix("/") || (FileManager.default.fileExists(atPath: out, isDirectory: &isDir) && isDir.boolValue)
        let ext = (out as NSString).pathExtension.lowercased()
        let still = !folder && (stillTypes[ext] != nil || (ext == "gif" && (mode == "image" || mode == "still")))
        if (mode == "video" || mode == "timelapse" || mode == "frames") && still {
            throw CLIError("\(outArg) is a still image format; use .mp4, .mov, .gif or a folder/ for \(mode)")
        }
        if (mode == "image" || mode == "still") && !still {
            throw CLIError("\(outArg) isn't an image format (png, jpg, heic, tiff)")
        }
        if !folder && !still && !["mp4", "mov", "m4v", "gif"].contains(ext) {
            throw CLIError("can't tell the format from \u{201C}\(outArg)\u{201D}: use .png .jpg .heic .tiff .mp4 .mov .gif or a folder/")
        }

        var config = try buildConfig(a, assignments: assignments, cwd: cwd)
        let size = try outputSize(a)
        LiveEarthFeeds.shared.allowNetwork = false
        HistoricalClouds.shared.blocking = true   // a past moment waits for that day's clouds
        let events = !a.has("--no-events")
        let quiet = a.has("--quiet")
        let time = try a.double("--time") ?? LockScreenStill.representativeTime(config)

        if still {
            try renderStill(config, size: size, time: time, events: events, smooth: a.has("--smooth"), to: out, ext: ext)
        } else {
            let fps = try a.int("--fps") ?? min(config.fps, 240)
            let duration = try a.double("--duration") ?? 10
            let speed = try a.double("--speed") ?? (mode == "timelapse" ? 60 : 1)
            guard fps > 0, fps <= 240, duration > 0, speed != 0 else { throw CLIError("--fps, --duration and --speed must be positive") }
            var blend = 0.0
            if a.has("--loop") { blend = 1 }
            if let s = try a.double("--loop") { blend = s }
            blend = min(blend, duration / 2)
            // Live Earth's clock follows the scene's, so a time-lapse shows the day going by
            if config.scene == .liveEarth { SceneParams.earthTimeLapse = 1 }
            config.fps = fps
            let movie = MotionPlan(config: config, width: size.width, height: size.height, smooth: a.has("--smooth"),
                                   start: time, duration: duration, fps: fps, speed: speed, blend: blend, events: events)
            let sink: FrameSink
            if folder {
                sink = try PNGSequenceSink(folder: out)
            } else if ext == "gif" {
                sink = try GIFSink(url: URL(fileURLWithPath: out), fps: fps, frames: movie.frames)
            } else {
                sink = try MovieSink(url: URL(fileURLWithPath: out), width: size.width, height: size.height, fps: fps,
                                     codec: a.value("--codec"), bitrate: try a.double("--bitrate"), mov: ext == "mov")
            }
            try movie.render(into: sink, progress: quiet ? nil : progressPrinter(movie.frames))
            try sink.finish()
        }
        if !quiet { CLI.stderr("Wrote \(out)") }
        if a.has("--open") { NSWorkspace.shared.open(URL(fileURLWithPath: out)) }
        return 0
    }

    // MARK: settings

    private static func buildConfig(_ a: ParsedArgs, assignments: [String], cwd: String) throws -> WallpaperConfig {
        var c = a.has("--defaults") ? WallpaperConfig() : savedConfig()
        if let s = a.value("--scene") { c.scene = try SceneKind.named(s, listedOnly: false, current: c.scene) }
        if let p = a.value("--preset") { try PresetLookup.apply(p, to: &c, cwd: cwd) }
        if let json = a.value("--config") {
            guard let patch = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw CLIError("--config takes a JSON object")
            }
            let list = patch.map { k, v in
                ConfigKeys.Assignment(key: k, raw: ConfigKeys.isColor(v) ? ConfigKeys.display(v) : ConfigKeys.json(v, pretty: false))
            }
            c = try ConfigKeys.apply(list, to: c, listedScenesOnly: false).config
        }
        let (patched, warnings) = try ConfigKeys.apply(try ConfigKeys.assignments(assignments), to: c, listedScenesOnly: false)
        warnings.forEach { CLI.stderr("note: \($0)") }
        c = patched
        if a.has("--smooth") {
            c.pixelSize = 1
            c.levels = 256
            c.dither = .bayer8
        }
        // every option that can change the scene is in c by now
        let demos = try demoEvents(a, scene: c.scene)
        if !demos.isEmpty { ConfigStore.shared.demoEvents.merge(demos) { _, new in new } }
        return c
    }

    /// Every `--demo` given, each a comma-separated list of NAME:SECONDS, as event kind id to
    /// start time. An event named more than once starts at the last time given.
    static func demoEvents(_ a: ParsedArgs, scene: SceneKind) throws -> [UInt64: Double] {
        var starts: [UInt64: Double] = [:]
        for demo in a.values("--demo") {
            for pair in demo.split(separator: ",") {
                let parts = pair.split(separator: ":").map(String.init)
                guard parts.count == 2, let start = Double(parts[1]),
                      let e = EventSchedule.named.first(where: { $0.name.caseInsensitiveCompare(parts[0]) == .orderedSame || String($0.kind.id) == parts[0] })
                else { throw CLIError("--demo takes NAME:SECONDS, like supernova:300") }
                if let reason = EventSchedule.realSkyReason(e, in: scene) { throw CLIError(reason) }
                starts[e.kind.id] = start
            }
        }
        return starts
    }

    /// The running app's settings (they may not be saved yet), or the saved ones.
    private static func savedConfig() -> WallpaperConfig {
        if let reply = CLIClient.send(["get", "--raw"], cwd: "/"), reply.code == 0,
           let c = WallpaperConfig.decode(Data(reply.out.utf8)) {
            return c
        }
        return ConfigStore.shared.config
    }

    private static func outputSize(_ a: ParsedArgs) throws -> (width: Int, height: Int) {
        var w = 0, h = 0
        if let s = a.value("--size") {
            let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw CLIError("--size takes WIDTHxHEIGHT, like 3840x2160") }
            (w, h) = (parts[0], parts[1])
        } else if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.pixelWidth > 0 {
            (w, h) = (mode.pixelWidth, mode.pixelHeight)
        } else {
            (w, h) = (3840, 2160)
        }
        if let k = try a.double("--scale") {
            guard k > 0 else { throw CLIError("--scale must be positive") }
            w = max(1, Int((Double(w) * k).rounded()))
            h = max(1, Int((Double(h) * k).rounded()))
        }
        guard w * h <= 16384 * 16384 else { throw CLIError("that's too big to render") }
        return (w, h)
    }

    private static func progressPrinter(_ total: Int) -> (Int) -> Void {
        let tty = isatty(STDERR_FILENO) != 0
        let start = Date()
        return { done in
            guard tty || done == total else { return }
            let elapsed = Date().timeIntervalSince(start)
            let eta = done > 0 ? elapsed / Double(done) * Double(total - done) : 0
            let line = "Rendering frame \(done)/\(total)" + (done < total ? String(format: ", about %.0f s left", eta) : "")
            FileHandle.standardError.write(Data(((tty ? "\r\u{1B}[K" : "") + line + (done == total ? "\n" : "")).utf8))
        }
    }

    // MARK: still

    private static func renderStill(_ c: WallpaperConfig, size: (width: Int, height: Int), time: Double, events: Bool,
                                    smooth: Bool, to path: String, ext: String) throws {
        let px = c.pixelSize
        let w = (size.width + px - 1) / px, h = (size.height + px - 1) / px
        guard let frame = FrameCapture.render(config: c, width: w, height: h, time: time, eventsEnabled: events),
              let image = FrameCapture.upscaled(frame, factor: px, width: size.width, height: size.height, nearest: !smooth)
        else { throw CLIError("rendering failed") }
        let type = stillTypes[ext] ?? .gif
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil) else {
            throw CLIError("can't write \(path)")
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CLIError("can't write \(path)") }
    }
}

// MARK: motion

/// The frames of a video: `frames` evenly spaced output frames, the scene clock running `speed`
/// times as fast from `start`. With `blend`, the last `blend` seconds dissolve into the frames
/// just before the start (cell by cell when dithered), so the end leads back into the start.
struct MotionPlan {
    let config: WallpaperConfig
    let width: Int, height: Int
    let smooth: Bool
    let start, duration: Double
    let fps: Int
    let speed, blend: Double
    let events: Bool

    var frames: Int { max(1, Int((duration * Double(fps)).rounded())) }

    func render(into sink: FrameSink, progress: ((Int) -> Void)?) throws {
        let px = config.pixelSize
        let sw = (width + px - 1) / px, sh = (height + px - 1) / px
        guard let seq = FrameCapture.Sequence(config: config, width: sw, height: sh, eventsEnabled: events) else {
            throw CLIError("couldn't set up the scene")
        }
        let n = frames
        let k = Int((blend * Double(fps)).rounded())
        let span = Double(n) / Double(fps) * speed     // scene seconds the video covers
        for i in 0..<n {
            let t = start + Double(i) / Double(fps) * speed
            guard var frame = seq.frame(time: t, orbitTime: t) else { throw CLIError("rendering frame \(i) failed") }
            if k > 0 && i >= n - k {
                let weight = Double(i - (n - k) + 1) / Double(k + 1)
                let earlier = t - span
                guard let b = seq.frame(time: earlier, orbitTime: earlier),
                      let mixed = MobileExport.dissolve(frame, b, weight: weight, cells: !smooth) else {
                    throw CLIError("blending frame \(i) failed")
                }
                frame = mixed
            }
            guard let image = FrameCapture.upscaled(frame, factor: px, width: width, height: height, nearest: !smooth) else {
                throw CLIError("scaling frame \(i) failed")
            }
            try sink.append(image, index: i)
            progress?(i + 1)
        }
    }
}

protocol FrameSink {
    func append(_ image: CGImage, index: Int) throws
    func finish() throws
}

final class PNGSequenceSink: FrameSink {
    let folder: URL
    init(folder: String) throws {
        self.folder = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }
    func append(_ image: CGImage, index: Int) throws {
        try FrameCapture.writePNG(image, to: folder.appendingPathComponent(String(format: "frame_%05d.png", index + 1)))
    }
    func finish() throws {}
}

final class GIFSink: FrameSink {
    private let dest: CGImageDestination
    private let frameProps: CFDictionary
    private let path: String

    init(url: URL, fps: Int, frames: Int) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw CLIError("can't write \(url.path)")
        }
        dest = d
        path = url.path
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(fps),
                                                      kCGImagePropertyGIFUnclampedDelayTime: 1 / Double(fps)]] as CFDictionary
    }
    func append(_ image: CGImage, index: Int) throws { CGImageDestinationAddImage(dest, image, frameProps) }
    func finish() throws {
        guard CGImageDestinationFinalize(dest) else { throw CLIError("can't write \(path)") }
    }
}

/// H.264 or HEVC in MP4 or QuickTime, or ProRes 4444 in QuickTime for editing.
final class MovieSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width, height, fps: Int

    init(url: URL, width w0: Int, height h0: Int, fps: Int, codec name: String?, bitrate: Double?, mov: Bool) throws {
        // 4:2:0 video needs even sizes; an odd last column or row is left out
        width = w0 & ~1
        height = h0 & ~1
        self.fps = fps
        let codec: AVVideoCodecType
        switch name?.lowercased() ?? (mov ? "hevc" : "h264") {
        case "h264", "avc": codec = .h264
        case "hevc", "h265": codec = .hevc
        case "prores", "prores4444":
            guard mov else { throw CLIError("ProRes needs a .mov file") }
            codec = .proRes4444
        default: throw CLIError("--codec takes h264, hevc or prores")
        }
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: mov ? .mov : .mp4)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        if codec != .proRes4444 {
            // dithered frames are mostly hard-edged cells, which need more bits than camera video
            let bits = bitrate.map { $0 * 1_000_000 } ?? Double(width * height * fps) * 0.25
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bits,
                                                         AVVideoExpectedSourceFrameRateKey: fps,
                                                         AVVideoMaxKeyFrameIntervalKey: fps * 2]
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw CLIError("this Mac can't encode \(codec.rawValue) at \(width)x\(height)")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw CLIError("can't add a video track") }
        writer.add(input)
        guard writer.startWriting() else { throw CLIError("can't write \(url.path): \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, index: Int) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw CLIError("encoding failed: \(writer.error?.localizedDescription ?? "")") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard let pool = adaptor.pixelBufferPool else { throw CLIError("encoding failed: \(writer.error?.localizedDescription ?? "no buffers")") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pb = buffer else { throw CLIError("encoding failed: no pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: info) {
            ctx.interpolationQuality = .none
            // top-left aligned, so a dropped odd column or row comes off the right and bottom
            ctx.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else {
            throw CLIError("encoding failed: \(writer.error?.localizedDescription ?? "")")
        }
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        if writer.status != .completed { throw CLIError("encoding failed: \(writer.error?.localizedDescription ?? "")") }
    }
}
