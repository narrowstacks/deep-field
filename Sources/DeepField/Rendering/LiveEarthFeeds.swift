import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Live Earth's two live layers: the latest global cloud map and NOAA's aurora forecast. Each is
/// fetched while the scene is showing and its layer is on, saved to Application Support, and
/// read back from there on later launches, so the scene keeps its last clouds and aurora with no
/// connection. Before the first fetch ever succeeds, a copy bundled in Resources/Earth stands in.
///
/// Sources (both free, no key):
/// - clouds: https://clouds.matteason.co.uk, a global infrared cloud composite from geostationary
///   weather satellites, refreshed every 3 hours (centered on 0 degrees, like our maps)
/// - aurora: NOAA SWPC's OVATION model, the chance of aurora overhead on a 1 degree grid for the
///   next half hour or so, refreshed every few minutes
final class LiveEarthFeeds {
    static let shared = LiveEarthFeeds()

    enum Feed: CaseIterable {
        case clouds, aurora

        var url: URL {
            switch self {
            case .clouds: URL(string: "https://clouds.matteason.co.uk/images/2048x1024/clouds.jpg")!
            case .aurora: URL(string: "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json")!
            }
        }
        /// The image kept on disk (the aurora's JSON is turned into an image first).
        var fileName: String { self == .clouds ? "clouds.jpg" : "aurora.png" }
        var fallbackName: String { self == .clouds ? "clouds-fallback.jpg" : "aurora-fallback.png" }
        /// How often the source changes, so how often it's worth asking.
        var refreshInterval: TimeInterval { self == .clouds ? 3 * 3600 : 20 * 60 }
    }

    struct State {
        var texture: MTLTexture?
        /// When the data on disk was fetched; nil while showing the bundled copy.
        var fetched: Date?
        var lastAttempt: Date?
        var inFlight = false
        var failed = false
        var loaded = false
    }

    private let lock = NSLock()
    private var states: [Feed: State] = [:]
    /// Off for command-line renders, so a snapshot never reaches the network.
    var allowNetwork = true
    /// Off for command-line renders too (unless `--live-earth-cache`), so they read the bundled
    /// maps and come out the same every time.
    var useCache = true

    private init() {}

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeepField/LiveEarth", isDirectory: true)
    }

    private func cacheURL(_ feed: Feed) -> URL { Self.directory.appendingPathComponent(feed.fileName) }

    /// The feed's texture for this frame. Loads it from disk the first time and asks for a fresh
    /// copy in the background when it's out of date; the new one shows on a later frame.
    func texture(_ feed: Feed, _ device: MTLDevice, _ queue: MTLCommandQueue) -> MTLTexture? {
        lock.lock()
        var st = states[feed] ?? State()
        if !st.loaded {
            st.loaded = true
            let cached = cacheURL(feed)
            if useCache, let tex = EarthMaps.load(cached, device, queue) {
                st.texture = tex
                st.fetched = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            } else if let url = EarthMaps.bundled(feed.fallbackName) {
                st.texture = EarthMaps.load(url, device, queue)
            }
        }
        let now = Date()
        let stale = st.fetched.map { now.timeIntervalSince($0) > feed.refreshInterval } ?? true
        // after a failure, wait a while before trying again
        let retryOK = st.lastAttempt.map { now.timeIntervalSince($0) > (st.failed ? 600 : 60) } ?? true
        let fetch = allowNetwork && stale && retryOK && !st.inFlight
        if fetch {
            st.inFlight = true
            st.lastAttempt = now
        }
        states[feed] = st
        lock.unlock()
        if fetch { refresh(feed, device, queue) }
        return st.texture
    }

    /// When the feed's data was fetched (nil: the bundled copy, or never loaded), and whether the
    /// last attempt to update it failed.
    func status(_ feed: Feed) -> (fetched: Date?, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let st = states[feed]
        let onDisk = (try? cacheURL(feed).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (st?.fetched ?? onDisk, st?.failed ?? false)
    }

    private func refresh(_ feed: Feed, _ device: MTLDevice, _ queue: MTLCommandQueue, done: (() -> Void)? = nil) {
        var request = URLRequest(url: feed.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("DeepField", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            var texture: MTLTexture?
            if ok, let data, error == nil, let file = self.store(feed, data) {
                texture = EarthMaps.load(file, device, queue)
            }
            self.lock.lock()
            var st = self.states[feed] ?? State()
            st.inFlight = false
            st.failed = texture == nil
            if let texture {
                st.texture = texture
                st.fetched = Date()
            }
            self.states[feed] = st
            self.lock.unlock()
            if texture == nil {
                NSLog("DeepField: couldn't update the Live Earth \(feed) map: \(error?.localizedDescription ?? "bad response")")
            }
            done?()
        }.resume()
    }

    /// Writes the fetched data to the cache as an image, replacing the old one only when the
    /// new one is good.
    private func store(_ feed: Feed, _ data: Data) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = cacheURL(feed)
        switch feed {
        case .clouds:
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil), image.width >= 512 else { return nil }
            do { try data.write(to: url, options: .atomic) } catch { return nil }
        case .aurora:
            guard let pixels = Self.auroraGrid(data) else { return nil }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: 360, height: 181, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 360,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            let tmp = url.appendingPathExtension("tmp")
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            _ = try? fm.replaceItemAt(url, withItemAt: tmp)
            if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: tmp, to: url) }
        }
        return url
    }

    /// NOAA's OVATION JSON as a 360x181 grid: column i is longitude i degrees east, row j latitude
    /// 90 - j, value the percent chance of aurora overhead scaled to 0...255 (as in
    /// make_earth_maps.py's aurora_fallback).
    static func auroraGrid(_ data: Data) -> [UInt8]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coords = json["coordinates"] as? [[Double]], coords.count > 1000 else { return nil }
        var grid = [UInt8](repeating: 0, count: 360 * 181)
        for c in coords where c.count >= 3 {
            let lon = (Int(c[0].rounded()) % 360 + 360) % 360, lat = Int(c[1].rounded())
            guard (-90...90).contains(lat) else { continue }
            grid[(90 - lat) * 360 + lon] = UInt8(min(max(c[2] * 2.55 + 0.5, 0), 255))
        }
        return grid
    }

    /// `--fetch-live-earth`: fetch both feeds now and wait, so the cache is fresh.
    func fetchNow(_ device: MTLDevice, _ queue: MTLCommandQueue) -> Bool {
        let group = DispatchGroup()
        for feed in Feed.allCases {
            group.enter()
            lock.lock()
            states[feed, default: State()].inFlight = true
            lock.unlock()
            refresh(feed, device, queue) { group.leave() }
        }
        group.wait()
        var ok = true
        for feed in Feed.allCases {
            let s = status(feed)
            print("\(feed): \(s.failed ? "failed" : "saved to \(cacheURL(feed).path)")")
            ok = ok && !s.failed
        }
        return ok
    }
}
