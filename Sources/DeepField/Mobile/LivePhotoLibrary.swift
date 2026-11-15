import AVFoundation
import ImageIO
import Photos

/// The Photos side of the Live Photo export: adding the pair to the library (which syncs it to
/// an iPhone through iCloud Photos), and checking a pair without touching the library.
enum LivePhotoLibrary {
    enum SaveError: LocalizedError {
        case denied, failed(String)
        var errorDescription: String? {
            switch self {
            case .denied: "Deep Field isn't allowed to add to Photos. Allow it in System Settings > Privacy & Security > Photos."
            case .failed(let s): "Photos didn't take it: \(s)"
            }
        }
    }

    /// Asks for add-only access the first time (macOS shows its prompt), then adds the still and
    /// the movie as one Live Photo. `completion` runs on the main queue.
    static func save(_ files: MobileExport.LivePhotoFiles, completion: @escaping (Error?) -> Void) {
        func finish(_ e: Error?) { DispatchQueue.main.async { completion(e) } }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return finish(SaveError.denied) }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: files.still, options: nil)
                request.addResource(with: .pairedVideo, fileURL: files.movie, options: nil)
            }, completionHandler: { ok, error in
                finish(ok ? nil : SaveError.failed(error?.localizedDescription ?? "unknown error"))
            })
        }
    }

    /// Loads the pair as a Live Photo the way Photos does, without adding it to the library.
    /// `completion` gets nil when it's a valid Live Photo, else what went wrong (main queue).
    static func validate(_ still: URL, _ movie: URL, completion: @escaping (String?) -> Void) {
        var done = false
        PHLivePhoto.request(withResourceFileURLs: [still, movie], placeholderImage: nil, targetSize: .zero,
                            contentMode: .aspectFit) { photo, info in
            guard !done else { return }
            if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                done = true
                DispatchQueue.main.async { completion(error.localizedDescription) }
            } else if info[PHLivePhotoInfoCancelledKey] as? Bool == true {
                done = true
                DispatchQueue.main.async { completion("cancelled") }
            } else if photo != nil, info[PHLivePhotoInfoIsDegradedKey] as? Bool != true {
                done = true
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// A readable dump of the pairing metadata (dev: `--mobile-export --live`).
    static func inspect(_ still: URL, _ movie: URL) -> String {
        var lines: [String] = []
        if let src = CGImageSourceCreateWithURL(still as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
            lines.append("still: \(CGImageSourceGetType(src) as String? ?? "?") \(props[kCGImagePropertyPixelWidth] ?? "?")x\(props[kCGImagePropertyPixelHeight] ?? "?"), MakerApple 17 = \(maker?["17"] ?? "missing")")
        } else {
            lines.append("still: unreadable")
        }
        let asset = AVURLAsset(url: movie)
        let sem = DispatchSemaphore(value: 0)
        var movieLines: [String] = []
        Task.detached {
            defer { sem.signal() }
            do {
                for item in try await asset.loadMetadata(for: .quickTimeMetadata) {
                    let key = item.identifier?.rawValue ?? "?"
                    let value = try await item.load(.stringValue) ?? "?"
                    movieLines.append("movie metadata: \(key) = \(value)")
                }
                let duration = try await asset.load(.duration)
                for track in try await asset.load(.tracks) {
                    let (descs, size, rate) = try await track.load(.formatDescriptions, .naturalSize, .nominalFrameRate)
                    for d in descs {
                        let sub = CMFormatDescriptionGetMediaSubType(d)
                        let fourcc = String(bytes: withUnsafeBytes(of: sub.bigEndian) { Array($0) }, encoding: .ascii) ?? "?"
                        var line = "track \(track.trackID): \(track.mediaType.rawValue) \(fourcc)"
                        if track.mediaType == .video {
                            line += " \(Int(size.width))x\(Int(size.height)) \(rate) fps, \(String(format: "%.2f", duration.seconds)) s"
                        }
                        if track.mediaType == .metadata, let ids = CMMetadataFormatDescriptionGetIdentifiers(d) as? [String] {
                            line += " \(ids)"
                        }
                        movieLines.append(line)
                    }
                    if track.mediaType == .metadata {
                        let reader = try AVAssetReader(asset: asset)
                        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                        reader.add(output)
                        let groups = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
                        reader.startReading()
                        while let g = groups.nextTimedMetadataGroup() {
                            for item in g.items {
                                let value = try await item.load(.value)
                                movieLines.append("  at \(String(format: "%.3f", g.timeRange.start.seconds)) s: \(item.identifier?.rawValue ?? "?") = \(value.map { "\($0)" } ?? "nil")")
                            }
                        }
                    }
                }
            } catch {
                movieLines.append("movie: \(error.localizedDescription)")
            }
        }
        if Thread.isMainThread {
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        } else {
            sem.wait()
        }
        return (lines + movieLines).joined(separator: "\n")
    }
}
