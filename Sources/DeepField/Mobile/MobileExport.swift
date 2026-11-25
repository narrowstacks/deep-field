import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An iPhone screen, in portrait pixels.
struct PhoneModel: Hashable, Identifiable {
    let key: String          // for `--device`
    let name: String
    let width: Int, height: Int
    var id: String { key }

    static let presets: [PhoneModel] = [
        PhoneModel(key: "17-pro-max", name: "iPhone 17 Pro Max, 16 Pro Max", width: 1320, height: 2868),
        PhoneModel(key: "air", name: "iPhone Air", width: 1260, height: 2736),
        PhoneModel(key: "17-pro", name: "iPhone 17, 17 Pro, 16 Pro", width: 1206, height: 2622),
        PhoneModel(key: "16-plus", name: "iPhone 16 Plus, 15 Plus, 15 Pro Max, 14 Pro Max", width: 1290, height: 2796),
        PhoneModel(key: "16", name: "iPhone 16, 15, 15 Pro, 14 Pro", width: 1179, height: 2556),
        PhoneModel(key: "16e", name: "iPhone 16e, 14, 13, 13 Pro, 12, 12 Pro", width: 1170, height: 2532),
        PhoneModel(key: "14-plus", name: "iPhone 14 Plus, 13 Pro Max, 12 Pro Max", width: 1284, height: 2778),
        PhoneModel(key: "13-mini", name: "iPhone 13 mini, 12 mini", width: 1080, height: 2340),
        PhoneModel(key: "11", name: "iPhone 11, XR", width: 828, height: 1792),
        PhoneModel(key: "se", name: "iPhone SE (2nd and 3rd generation)", width: 750, height: 1334),
    ]
}

/// What the Mobile tab (or `--mobile-export`) asks for, on top of the current scene settings.
struct MobileOptions: Equatable {
    var width = 1320, height = 2868
    var smooth = false
    var pixelSize = 0              // 0 = automatic
    var framing = PhoneFraming()
    /// How much faster than the wallpaper the Live Photo moves (its 3 s would barely show the
    /// wallpaper's slow drift).
    var motionSpeed = 2.0

    static let sizeRange = 320...4096   // per side; the video encoder's limit is well above this
    static func clampedSide(_ v: Int) -> Int { min(max(v, sizeRange.lowerBound), sizeRange.upperBound) }

    /// The cell size used when `pixelSize` is automatic. A phone sits about twice as close as
    /// a desktop display at about twice the density, so the wallpaper's own cell size would look
    /// about the same; one notch larger keeps the dither readable on the small screen.
    static func autoPixelSize(desktop: Int) -> Int {
        min(max(Int((Double(desktop) * 1.34).rounded()), 2), 12)
    }

    func resolvedPixelSize(desktop: Int) -> Int {
        pixelSize > 0 ? min(pixelSize, 16) : Self.autoPixelSize(desktop: desktop)
    }
}

/// Renders the current scene as an iPhone wallpaper: a portrait still, and a short loop paired
/// with it as a Live Photo (a HEIC still and a QuickTime movie that share a content identifier).
enum MobileExport {
    /// Everything needed to render: the adjusted config, the output size, and the shaded size.
    struct Plan {
        let config: WallpaperConfig
        let width: Int, height: Int
        let factor: Int                 // output pixels per shaded pixel
        let nearest: Bool               // crisp cells (dithered) or smooth upscaling
        var shadedWidth: Int { (width + factor - 1) / factor }
        var shadedHeight: Int { (height + factor - 1) / factor }
        let stillTime: Double
        let loop: Loop
    }

    /// The Live Photo's motion: `duration` seconds at `fps`, with the still in the middle,
    /// covering `speed` times as much scene time. The last `fade` seconds dissolve into the
    /// frames before the start, so it loops.
    struct Loop {
        let duration: Double, fps: Int, fade: Double, speed: Double
        var frames: Int { Int((duration * Double(fps)).rounded()) }
        var stillOffset: Double { duration / 2 }
    }

    static func plan(_ base: WallpaperConfig, _ o: MobileOptions) -> Plan {
        var c = base
        c.lockScreenStill = false
        c.phoneFraming = o.framing
        // only continuous motion: no transient events of any kind
        c.supernovae = .off; c.comets = .off; c.wormholeEvents = .off; c.cometEvents = .off; c.starFlares = .off
        let w = MobileOptions.clampedSide(o.width), h = MobileOptions.clampedSide(o.height)
        let factor: Int
        if o.smooth {
            c = LockScreenStill.stillConfig({ var s = c; s.lockScreenSmooth = true; return s }())
            factor = max(1, Int((Double(w * h) / LockScreenStill.maxShadedPixels).squareRoot().rounded(.up)))
        } else {
            factor = o.resolvedPixelSize(desktop: base.pixelSize)
            c.pixelSize = factor
        }
        c.lockScreenSmooth = false
        return Plan(config: c, width: w, height: h, factor: factor, nearest: !o.smooth,
                    stillTime: stillTime(c), loop: loop(for: c, speed: o.motionSpeed))
    }

    /// The lock screen still's moment, except that the binary pair is caught further apart
    /// across the narrow frame (there the lock screen's moment has one star behind the other).
    static func stillTime(_ c: WallpaperConfig) -> Double {
        c.scene == .binary ? 0.62 * c.starOrbitMinutes * 60 : LockScreenStill.representativeTime(c)
    }

    /// About 3 s. The pulsar's loop is a whole number of turns, so its beams come round exactly.
    static func loop(for c: WallpaperConfig, speed: Double) -> Loop {
        let speed = min(max(speed, 0.25), 8)
        var d = 3.0
        if c.scene == .pulsar {
            let p = max(c.pulsarPeriod, 0.2) / speed
            let turns = max(1, (3 / p).rounded())
            if turns * p >= 1.5 && turns * p <= 4 { d = turns * p }
        }
        return Loop(duration: d, fps: 30, fade: d * 0.3, speed: speed)
    }

    // MARK: still

    static func renderStill(_ plan: Plan) -> CGImage? {
        guard let seq = FrameCapture.Sequence(config: plan.config, width: plan.shadedWidth, height: plan.shadedHeight),
              let frame = seq.frame(time: plan.stillTime, orbitTime: plan.stillTime) else { return nil }
        return upscale(frame, plan)
    }

    static func upscale(_ frame: CGImage, _ plan: Plan) -> CGImage? {
        FrameCapture.upscaled(frame, factor: plan.factor, width: plan.width, height: plan.height, nearest: plan.nearest)
    }

    enum StillFormat { case png, heic }

    static func writeStill(_ image: CGImage, to url: URL, format: StillFormat, assetIdentifier: String? = nil) throws {
        if format == .png { return try FrameCapture.writePNG(image, to: url) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        // the Live Photo pairing: Apple's maker note key 17 holds the asset identifier
        if let assetIdentifier { props[kCGImagePropertyMakerAppleDictionary] = ["17": assetIdentifier] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: loop

    /// Calls `body` with each frame of the loop at the shaded size, in order. Frames in the last
    /// `fade` seconds dissolve into the frames one loop earlier, so the last frame leads into the
    /// first: cell by cell along an ordered-dither threshold when dithered (every cell keeps a
    /// palette color), a plain cross-fade when smooth.
    static func renderLoop(_ plan: Plan, progress: (Double) -> Void = { _ in },
                           body: (Int, CGImage) throws -> Void) throws {
        let loop = plan.loop
        let w = plan.shadedWidth, h = plan.shadedHeight
        guard let seq = FrameCapture.Sequence(config: plan.config, width: w, height: h) else { throw ExportError.render }
        let k = loop.speed
        let start = plan.stillTime - loop.stillOffset * k, orbit = plan.stillTime
        for i in 0..<loop.frames {
            let tau = Double(i) / Double(loop.fps)
            guard let a = seq.frame(time: start + tau * k, orbitTime: orbit) else { throw ExportError.render }
            let fadeStart = loop.duration - loop.fade
            if tau > fadeStart {
                let x = (tau - fadeStart) / loop.fade
                let weight = x * x * (3 - 2 * x)
                guard let b = seq.frame(time: start + (tau - loop.duration) * k, orbitTime: orbit),
                      let mixed = dissolve(a, b, weight: weight, cells: plan.nearest) else { throw ExportError.render }
                try body(i, mixed)
            } else {
                try body(i, a)
            }
            progress(Double(i + 1) / Double(loop.frames))
        }
    }

    private static let bayer8: [Int] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ]

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }

    static func dissolve(_ a: CGImage, _ b: CGImage, weight: Double, cells: Bool) -> CGImage? {
        guard var pa = pixels(a), let pb = pixels(b) else { return nil }
        let w = a.width, h = a.height
        if cells {
            // a cell switches to b once the weight passes its threshold
            let level = Int(weight * 64)
            for y in 0..<h {
                for x in 0..<w where bayer8[(y & 7) * 8 + (x & 7)] < level {
                    let o = (y * w + x) * 4
                    pa[o] = pb[o]; pa[o + 1] = pb[o + 1]; pa[o + 2] = pb[o + 2]
                }
            }
        } else {
            let k = Float(weight)
            for i in 0..<pa.count { pa[i] = UInt8((Float(pa[i]) * (1 - k) + Float(pb[i]) * k).rounded()) }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(pa) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    enum ExportError: LocalizedError {
        case render, writer(String)
        var errorDescription: String? {
            switch self {
            case .render: "Rendering failed."
            case .writer(let s): "Couldn't write the movie: \(s)"
            }
        }
    }

    // MARK: movie

    /// Writes the loop as a movie at the output size. With `assetIdentifier` it's the Live
    /// Photo half (HEVC QuickTime with the content identifier and a still-image-time track);
    /// without, an H.264 MP4 that repeats the loop `repeats` times (a preview to share).
    static func writeMovie(_ plan: Plan, to url: URL, assetIdentifier: String?, repeats: Int = 1,
                           progress: (Double) -> Void = { _ in }) throws {
        try? FileManager.default.removeItem(at: url)
        let live = assetIdentifier != nil
        let writer = try AVAssetWriter(outputURL: url, fileType: live ? .mov : .mp4)
        // 4:2:0 video needs even sizes; an odd last column or row is left out (iPhone 16: 1179)
        let w = plan.width & ~1, h = plan.height & ~1, fps = plan.loop.fps
        let bitRate = Double(w * h * fps) * 0.25
        func settings(_ codec: AVVideoCodecType) -> [String: Any] {
            [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
             AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
             AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate,
                                               AVVideoExpectedSourceFrameRateKey: fps,
                                               AVVideoMaxKeyFrameIntervalKey: fps]]
        }
        var videoSettings = settings(live ? .hevc : .h264)
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) { videoSettings = settings(.h264) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(input) else { throw ExportError.writer("no video input") }
        writer.add(input)

        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let assetIdentifier {
            let id = AVMutableMetadataItem()
            id.keySpace = .quickTimeMetadata
            id.key = "com.apple.quicktime.content.identifier" as NSString
            id.value = assetIdentifier as NSString
            id.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata = [id]
            // a timed metadata track marking where in the movie the still was taken
            let spec: [String: Any] = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
            var desc: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc)
            let metaInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
            guard writer.canAdd(metaInput) else { throw ExportError.writer("no metadata input") }
            writer.add(metaInput)
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
        }

        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)
        func wait(_ i: AVAssetWriterInput) throws {
            while !i.isReadyForMoreMediaData {
                if writer.status == .failed { throw ExportError.writer(writer.error?.localizedDescription ?? "failed") }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        if let metadataAdaptor {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.apple.quicktime.still-image-time" as NSString
            item.value = -1 as NSNumber          // 0xFF, as the camera writes it
            item.dataType = kCMMetadataBaseDataType_SInt8 as String
            let at = CMTime(seconds: plan.loop.stillOffset, preferredTimescale: 600)
            try wait(metadataAdaptor.assetWriterInput)
            metadataAdaptor.append(AVTimedMetadataGroup(items: [item],
                                                        timeRange: CMTimeRange(start: at, duration: CMTime(value: 1, timescale: 600))))
            metadataAdaptor.assetWriterInput.markAsFinished()
        }

        let frames = plan.loop.frames
        let total = frames * max(repeats, 1)
        var cached: [CGImage] = []   // repeats reuse the shaded frames (small) instead of re-rendering
        func append(_ shaded: CGImage, at index: Int) throws {
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer(writer.error?.localizedDescription ?? "no buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw ExportError.writer("no pixel buffer") }
            draw(shaded, into: pb, width: w, height: h, plan)
            try wait(input)
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append failed")
            }
            progress(Double(index + 1) / Double(total))
        }
        try renderLoop(plan) { i, frame in
            if repeats > 1 { cached.append(frame) }
            try append(frame, at: i)
        }
        for r in 1..<max(repeats, 1) {
            for (i, frame) in cached.enumerated() { try append(frame, at: r * frames + i) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        if Thread.isMainThread {
            while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        } else {
            done.wait()
        }
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "unfinished") }
    }

    /// Upscales a shaded frame into a pixel buffer, top-left aligned like `FrameCapture.upscaled`.
    private static func draw(_ shaded: CGImage, into pb: CVPixelBuffer, width: Int, height: Int, _ plan: Plan) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return }
        ctx.interpolationQuality = plan.nearest ? .none : .high
        let sw = shaded.width * plan.factor, sh = shaded.height * plan.factor
        ctx.draw(shaded, in: CGRect(x: 0, y: height - sh, width: sw, height: sh))
    }

    // MARK: Live Photo

    struct LivePhotoFiles { let still: URL; let movie: URL; let assetIdentifier: String }

    /// Writes `<base>.HEIC` and `<base>.MOV` into `folder`. The still is the loop's middle frame.
    static func writeLivePhoto(_ plan: Plan, folder: URL, baseName: String,
                               progress: (Double) -> Void = { _ in }) throws -> LivePhotoFiles {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let still = folder.appendingPathComponent(baseName + ".HEIC"), movie = folder.appendingPathComponent(baseName + ".MOV")
        guard let image = renderStill(plan) else { throw ExportError.render }
        try writeStill(image, to: still, format: .heic, assetIdentifier: id)
        try writeMovie(plan, to: movie, assetIdentifier: id, progress: progress)
        return LivePhotoFiles(still: still, movie: movie, assetIdentifier: id)
    }

    /// A file name for the current scene and size, e.g. "Deep Field Black Hole 1320x2868".
    static func baseName(_ plan: Plan) -> String {
        "Deep Field \(plan.config.scene.title) \(plan.width)x\(plan.height)"
    }
}
