import Foundation
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers

/// Real clouds for past moments, so a frozen date shows that day's weather and a time-lapse shows
/// the clouds moving. Two free sources:
///
/// - NASA GIBS geostationary infrared (GOES-West, GOES-East, Himawari), every 10 minutes, kept
///   for about the last 2.5 months. Used when the visible part of Earth is North America and the
///   Pacific, which those three satellites cover.
/// - NOAA GridSat-B1, the global geostationary infrared record, every 3 hours since 1980 (up to a
///   month or two ago), through NCEI's OPeNDAP server.
///
/// Each frame becomes a cloud cover map (0 clear to 1 thick cloud), cached in Application Support.
/// Between two frames the clouds don't fade from one to the next: the motion between them is
/// worked out once (block matching) and the shader carries each frame's clouds along it
/// toward the other, so they drift the way they really moved.
final class HistoricalClouds {
    static let shared = HistoricalClouds()

    enum Source: String {
        case gibs, gridsat
        var step: TimeInterval { self == .gibs ? 600 : 10800 }
    }

    /// What the shader needs for one moment: the frames either side, the motion between them, and
    /// how far between them the moment is (0 at `a`, 1 at `b`).
    struct Moment {
        let a: MTLTexture, b: MTLTexture, flow: MTLTexture, fraction: Float
    }

    static let mapWidth = 2048, mapHeight = 1024
    static let flowWidth = 512, flowHeight = 256

    /// Command-line renders wait for downloads; the app asks in the background and shows the
    /// usual clouds until the frames are in.
    var blocking = false

    private let lock = NSLock()
    private var textures: [String: MTLTexture] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []
    private var failed: [String: Date] = [:]
    private var colormap: [UInt32: Float]?

    private init() {}

    static var directory: URL { LiveEarthFeeds.directory.appendingPathComponent("history", isDirectory: true) }

    // MARK: choosing a source

    /// The source for a moment seen from above `home` at `distance` Earth radii, or nil when the
    /// moment is too recent for either (then the live map stands in).
    static func source(for date: Date, home: SIMD3<Double>, distance: Double, now: Date = Date()) -> Source? {
        let age = now.timeIntervalSince(date)
        guard age > 2 * 3600 else { return nil }
        if age < 70 * 86400 && coveredByPacificSatellites(home: home, distance: distance) { return .gibs }
        return age > 20 * 86400 ? .gridsat : nil
    }

    /// Subsatellite longitudes, degrees: GOES-West, GOES-East, Himawari.
    static let satellites: [(layer: String, lon: Double)] = [
        ("GOES-West_ABI_Band13_Clean_Infrared", -137.0), ("GOES-East_ABI_Band13_Clean_Infrared", -75.2),
        ("Himawari_AHI_Band13_Clean_Infrared", 140.7),
    ]

    /// Whether what we can see below 65 degrees of latitude (where geostationary satellites see
    /// well) is within 72 degrees of one of the three satellites: North America and the Pacific.
    /// A few points at the far edge may fall outside (from high over California the view reaches
    /// round to Iceland); their clouds fade out there.
    static func coveredByPacificSatellites(home: SIMD3<Double>, distance: Double) -> Bool {
        let cap = acos(1 / max(distance, 1.01)) * 0.92
        let z = SIMD3<Double>(0, 0, 1)
        var e1 = simd_cross(z, home)
        if simd_length(e1) < 1e-6 { e1 = SIMD3(1, 0, 0) }
        e1 = simd_normalize(e1)
        let e2 = simd_cross(home, e1)
        var points = [home]
        for k in 0..<24 {
            let a = Double(k) / 24 * 2 * .pi
            for r in [cap * 0.5, cap] {
                points.append(cos(r) * home + sin(r) * (cos(a) * e1 + sin(a) * e2))
            }
        }
        let outside = points.filter { p in
            if abs(p.z) > sin(65 * Double.pi / 180) { return false }
            return !satellites.contains { sat in
                let s = Astronomy.point(latitude: 0, longitude: sat.lon)
                return acos(min(max(simd_dot(p, s), -1), 1)) < 72 * Double.pi / 180
            }
        }
        return Double(outside.count) <= 0.15 * Double(points.count)
    }

    // MARK: the moment's textures

    func moment(_ date: Date, source: Source, device: MTLDevice, queue: MTLCommandQueue) -> Moment? {
        let t0 = (date.timeIntervalSince1970 / source.step).rounded(.down) * source.step
        let t1 = t0 + source.step
        let fraction = Float((date.timeIntervalSince1970 - t0) / source.step)
        guard let a = texture(.map, source, t0, device, queue),
              let b = texture(.map, source, t1, device, queue),
              let flow = texture(.flow, source, t0, device, queue) else { return nil }
        return Moment(a: a, b: b, flow: flow, fraction: fraction)
    }

    private enum Kind: String { case map, flow }

    private func fileURL(_ kind: Kind, _ source: Source, _ t: Double) -> URL {
        let name = "\(Int(t))" + (kind == .map ? ".png" : ".flow")
        return Self.directory.appendingPathComponent(source.rawValue).appendingPathComponent(name)
    }

    private func texture(_ kind: Kind, _ source: Source, _ t: Double, _ device: MTLDevice, _ queue: MTLCommandQueue) -> MTLTexture? {
        let key = "\(source.rawValue)-\(kind.rawValue)-\(Int(t))"
        lock.lock()
        if let tex = textures[key] { lock.unlock(); return tex }
        if let when = failed[key], Date().timeIntervalSince(when) < 600 { lock.unlock(); return nil }
        lock.unlock()
        if let tex = loadCached(kind, source, t, device, queue) { return remember(key, tex) }
        if blocking {
            produce(kind, source, t)
            if let tex = loadCached(kind, source, t, device, queue) { return remember(key, tex) }
            lock.lock(); failed[key] = Date(); lock.unlock()
            return nil
        }
        lock.lock()
        let start = !pending.contains(key)
        if start { pending.insert(key) }
        lock.unlock()
        if start {
            DispatchQueue.global(qos: .utility).async {
                self.produce(kind, source, t)
                self.lock.lock()
                self.pending.remove(key)
                if !FileManager.default.fileExists(atPath: self.fileURL(kind, source, t).path) { self.failed[key] = Date() }
                self.lock.unlock()
            }
        }
        return nil
    }

    private func remember(_ key: String, _ tex: MTLTexture) -> MTLTexture {
        lock.lock()
        defer { lock.unlock() }
        textures[key] = tex
        order.removeAll { $0 == key }
        order.append(key)
        // a time-lapse walks through frames; keep the last few
        while order.count > 12 { textures[order.removeFirst()] = nil }
        return tex
    }

    private func loadCached(_ kind: Kind, _ source: Source, _ t: Double, _ device: MTLDevice, _ queue: MTLCommandQueue) -> MTLTexture? {
        let url = fileURL(kind, source, t)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if kind == .map { return EarthMaps.load(url, device, queue) }
        guard let data = try? Data(contentsOf: url), data.count == Self.flowWidth * Self.flowHeight * 8 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: Self.flowWidth,
                                                         height: Self.flowHeight, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        data.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, Self.flowWidth, Self.flowHeight), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: Self.flowWidth * 8)
        }
        return tex
    }

    /// Makes the file for a frame's map, or the flow from frame t to the next one.
    private func produce(_ kind: Kind, _ source: Source, _ t: Double) {
        let url = fileURL(kind, source, t)
        if FileManager.default.fileExists(atPath: url.path) { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch kind {
        case .map:
            guard var cover = source == .gibs ? gibsCover(t) : gridsatCover(t) else { return }
            // a light blur: the source is sampled every few points, which leaves a speckle
            for _ in 0..<2 { cover = Self.blur(cover, Self.mapWidth, Self.mapHeight, 1) }
            writeGray(cover, Self.mapWidth, Self.mapHeight, to: url)
        case .flow:
            produce(.map, source, t)
            produce(.map, source, t + source.step)
            guard let a = readGray(fileURL(.map, source, t)), let b = readGray(fileURL(.map, source, t + source.step)),
                  let flow = Self.opticalFlow(a, b) else { return }
            let data = flow.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Fetches every frame and flow a span needs, a few at a time, so parallel renders find them
    /// all cached (`--prefetch-history`).
    func prefetch(from start: Date, seconds: Double, source: Source) {
        let first = (start.timeIntervalSince1970 / source.step).rounded(.down) * source.step
        let last = start.timeIntervalSince1970 + seconds
        var times: [Double] = []
        var t = first
        while t <= last { times.append(t); t += source.step }
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 4)
        for t in times + [t] {
            group.enter(); gate.wait()
            DispatchQueue.global().async { self.produce(.map, source, t); gate.signal(); group.leave() }
        }
        group.wait()
        for t in times {
            group.enter(); gate.wait()
            DispatchQueue.global().async { self.produce(.flow, source, t); gate.signal(); group.leave() }
        }
        group.wait()
        let ok = times.filter { FileManager.default.fileExists(atPath: fileURL(.flow, source, $0).path) }.count
        print("\(source.rawValue): \(ok) of \(times.count) frame pairs ready in \(Self.directory.path)")
    }

    // MARK: brightness temperature to cloud

    /// How cloudy a pixel is from its infrared brightness temperature (K). Clouds read colder than
    /// the ground under them, and higher, thicker cloud colder still. What "warm ground" means
    /// changes with latitude and season (Canada in December is colder than a tropical cloud top),
    /// so the threshold follows a rough surface temperature for the place and time of year.
    static func cover(bt: Float, latitude: Double, dayOfYear: Double) -> Float {
        guard bt.isFinite, bt > 150 else { return 0 }
        let s = abs(sin(latitude * .pi / 180))
        // +1 in the hemisphere's midwinter, -1 in its midsummer
        let winter = cos(2 * .pi * (dayOfYear - 355) / 365.25) * (latitude >= 0 ? 1 : -1)
        let surface = 300 - 45 * s * s - 16 * winter * s
        // a few degrees under the ground starts low cloud; 40 under is thick, high cloud
        let clear = Float(surface - 6), thick = Float(surface - 40)
        let x = min(max((clear - bt) / (clear - thick), 0), 1)
        // low cloud reads warm but is just as white from above, so thin cover rises quickly
        return pow(x * x * (3 - 2 * x), 0.7)
    }

    private static func dayOfYear(_ t: Double) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return Double(cal.ordinality(of: .day, in: .year, for: Date(timeIntervalSince1970: t)) ?? 1)
    }

    // MARK: NOAA GridSat-B1

    private func gridsatCover(_ t: Double) -> [Float]? {
        let d = Date(timeIntervalSince1970: t)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour], from: d)
        guard let y = c.year, let m = c.month, let day = c.day, let h = c.hour else { return nil }
        let name = String(format: "GRIDSAT-B1.%04d.%02d.%02d.%02d.v02r01.nc", y, m, day, h)
        // OPeNDAP's binary form, every other point (0.14 degrees): the packed values as they're
        // stored. (The subset service turns this variable into all missing values.)
        let stride = 2, rows = 2000, cols = 5143
        let constraint = "irwin_cdr.irwin_cdr%5B0%5D%5B0:\(stride):\(rows - 1)%5D%5B0:\(stride):\(cols - 1)%5D"
        let url = URL(string: "https://www.ncei.noaa.gov/thredds/dodsC/cdr/gridsat/\(y)/\(name).dods?\(constraint)")!
        let nlat = (rows - 1) / stride + 1, nlon = (cols - 1) / stride + 1
        guard let data = Self.download(url), let bt = Self.dodsInt16(data, count: nlat * nlon, scale: 0.01, offset: 200,
                                                                    fill: -31999) else { return nil }
        let lat = (0..<nlat).map { Float(-70 + 0.07 * Double($0 * stride)) }
        let lon = (0..<nlon).map { Float(-180 + 0.07 * Double($0 * stride)) }
        let doy = Self.dayOfYear(t)
        let W = Self.mapWidth, H = Self.mapHeight
        let lat0 = Double(lat[0]), dlat = Double(lat[1] - lat[0]), lon0 = Double(lon[0]), dlon = Double(lon[1] - lon[0])
        var out = [Float](repeating: 0, count: W * H)
        for j in 0..<H {
            let la = 90 - (Double(j) + 0.5) / Double(H) * 180
            let row = Int(((la - lat0) / dlat).rounded())
            // the record stops near 70 degrees; fade out toward its edge instead of cutting off
            let edge = Float(min(max((70 - abs(la)) / 4, 0), 1))
            guard row >= 0, row < lat.count, edge > 0 else { continue }
            for i in 0..<W {
                let lo = -180 + (Double(i) + 0.5) / Double(W) * 360
                var col = Int(((lo - lon0) / dlon).rounded()) % lon.count
                if col < 0 { col += lon.count }
                out[j * W + i] = Self.cover(bt: bt[row * lon.count + col], latitude: la, dayOfYear: doy) * edge
            }
        }
        return out
    }

    /// The values of a DAP2 binary (.dods) response holding one 16-bit array: after the text
    /// header and "Data:", the element count twice, then each value as a 32-bit big-endian integer.
    static func dodsInt16(_ data: Data, count: Int, scale: Float, offset: Float, fill: Int32) -> [Float]? {
        guard let marker = data.range(of: Data("\nData:\n".utf8)) else { return nil }
        let start = marker.upperBound + 8
        guard data.count >= start + count * 4 else { return nil }
        var out = [Float](repeating: .nan, count: count)
        data.withUnsafeBytes { raw in
            for k in 0..<count {
                let v = Int32(bigEndian: raw.loadUnaligned(fromByteOffset: start + 4 * k, as: Int32.self))
                if v != fill { out[k] = Float(v) * scale + offset }
            }
        }
        return out
    }

    // MARK: NASA GIBS geostationary

    private func gibsCover(_ t: Double) -> [Float]? {
        guard let cmap = loadColormap() else { return nil }
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        let stamp = f.string(from: Date(timeIntervalSince1970: t))
        let W = Self.mapWidth, H = Self.mapHeight
        var sum = [Float](repeating: 0, count: W * H), weight = [Float](repeating: 0, count: W * H)
        var any = false
        // exact colors normally; the nearest colormap color if decoding shifted one slightly
        let entries = Array(cmap)
        var resolved: [UInt32: Float] = [:]
        func celsius(_ key: UInt32) -> Float {
            if let v = cmap[key] ?? resolved[key] { return v }
            let r = Int(key >> 16), g = Int(key >> 8 & 255), b = Int(key & 255)
            let best = entries.min { e1, e2 in
                func d(_ k: UInt32) -> Int { let dr = Int(k >> 16) - r, dg = Int(k >> 8 & 255) - g, db = Int(k & 255) - b; return dr * dr + dg * dg + db * db }
                return d(e1.key) < d(e2.key)
            }!
            resolved[key] = best.value
            return best.value
        }
        for sat in Self.satellites {
            let url = URL(string: "https://wvs.earthdata.nasa.gov/api/v1/snapshot?REQUEST=GetSnapshot&TIME=\(stamp)&BBOX=-90,-180,90,180&CRS=EPSG:4326&LAYERS=\(sat.layer)&FORMAT=image/png&WIDTH=\(W)&HEIGHT=\(H)")!
            guard let data = Self.download(url), let rgba = Self.decodeRGBA(data, W, H) else { continue }
            any = true
            let doy = Self.dayOfYear(t)
            let sub = Astronomy.point(latitude: 0, longitude: sat.lon)
            for j in 0..<H {
                let la = 90 - (Double(j) + 0.5) / Double(H) * 180
                for i in 0..<W {
                    let o = (j * W + i) * 4
                    guard rgba[o + 3] > 0 else { continue }
                    let key = UInt32(rgba[o]) << 16 | UInt32(rgba[o + 1]) << 8 | UInt32(rgba[o + 2])
                    let c = celsius(key)
                    guard c.isFinite else { continue }
                    let lo = -180 + (Double(i) + 0.5) / Double(W) * 360
                    // where satellites overlap, favor the one looking more nearly straight down,
                    // and fade each out toward the edge of its view
                    let view = acos(min(max(simd_dot(Astronomy.point(latitude: la, longitude: lo), sub), -1), 1)) * 180 / .pi
                    let w = Float(min(max((76 - view) / 14, 0), 1))
                    guard w > 0 else { continue }
                    sum[j * W + i] += w * Self.cover(bt: c + 273.15, latitude: la, dayOfYear: doy)
                    weight[j * W + i] += w
                }
            }
        }
        guard any else { return nil }
        return zip(sum, weight).map { s, w in w > 0 ? s / max(w, 1) : 0 }
    }

    /// GIBS paints its infrared frames with a color scale; its colormap gives the temperature
    /// (degrees C) behind each color, so the frames turn back into temperatures exactly.
    private func loadColormap() -> [UInt32: Float]? {
        lock.lock()
        if let c = colormap { lock.unlock(); return c }
        lock.unlock()
        let file = Self.directory.appendingPathComponent("band13-colormap.xml")
        var data = try? Data(contentsOf: file)
        if data == nil, let fetched = Self.download(URL(string: "https://gibs.earthdata.nasa.gov/colormaps/v1.3/Clean_Longwave_Infrared_Window_Band.xml")!) {
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? fetched.write(to: file, options: .atomic)
            data = fetched
        }
        guard let data, let xml = String(data: data, encoding: .utf8) else { return nil }
        var map: [UInt32: Float] = [:]
        let entry = try! NSRegularExpression(pattern: #"rgb="(\d+),(\d+),(\d+)"[^>]*?value="[\(\[]([-+0-9.INF]+),([-+0-9.INF]+)[\)\]]""#)
        for m in entry.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            func g(_ i: Int) -> String { String(xml[Range(m.range(at: i), in: xml)!]) }
            guard let r = UInt32(g(1)), let gr = UInt32(g(2)), let b = UInt32(g(3)) else { continue }
            let lo = Float(g(4)), hi = Float(g(5))
            let value = lo != nil && hi != nil ? (lo! + hi!) / 2 : (lo ?? hi ?? .nan)
            map[r << 16 | gr << 8 | b] = value
        }
        guard map.count > 100 else { return nil }
        lock.lock(); colormap = map; lock.unlock()
        return map
    }

    // MARK: optical flow

    /// The motion from map a to map b, in texture coordinates per frame step, at flow size. Block
    /// matching: for each point, the shift (up to about 3.5 degrees) that best lines up the
    /// cloud round it in a with b, then smoothed so neighboring clouds move together and glide
    /// instead of jittering. (Vision's optical flow, tried first, found well under half of the
    /// motion on these maps; this finds about what winds aloft carry clouds in a few hours.)
    static func opticalFlow(_ a: [UInt8], _ b: [UInt8]) -> [Float]? {
        let W = flowWidth, H = flowHeight, sx = mapWidth / W, sy = mapHeight / H
        func shrink(_ m: [UInt8]) -> [Float] {
            var out = [Float](repeating: 0, count: W * H)
            for j in 0..<H {
                for i in 0..<W {
                    var s = 0
                    for y in 0..<sy { for x in 0..<sx { s += Int(m[(j * sy + y) * mapWidth + i * sx + x]) } }
                    out[j * W + i] = Float(s) / Float(sx * sy * 255)
                }
            }
            return out
        }
        let A = shrink(a), B = shrink(b)
        let radius = 5, window = 4
        var best = [Float](repeating: .greatestFiniteMagnitude, count: W * H)
        var fx = [Float](repeating: 0, count: W * H), fy = fx
        var diff = [Float](repeating: 0, count: W * H)
        for dy in -radius...radius {
            for dx in -radius...radius {
                // how badly b, shifted back by (dx, dy), fails to match a round each point
                for j in 0..<H {
                    let y = min(max(j + dy, 0), H - 1)
                    for i in 0..<W {
                        let d = A[j * W + i] - B[y * W + ((i + dx) % W + W) % W]
                        diff[j * W + i] = d * d
                    }
                }
                let err = blur(diff, W, H, window)
                for k in 0..<(W * H) where err[k] < best[k] - 1e-7 {
                    best[k] = err[k]; fx[k] = Float(dx); fy[k] = Float(dy)
                }
            }
        }
        for _ in 0..<3 { fx = blur(fx, W, H, 3); fy = blur(fy, W, H, 3) }
        var out = [Float](repeating: 0, count: W * H * 2)
        for k in 0..<(W * H) {
            out[2 * k] = fx[k] / Float(W)
            out[2 * k + 1] = fy[k] / Float(H)
        }
        return out
    }

    private static func blur(_ v: [Float], _ W: Int, _ H: Int, _ r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: v.count), out = tmp
        for j in 0..<H {
            for i in 0..<W {
                var s: Float = 0
                for d in -r...r { s += v[j * W + ((i + d) % W + W) % W] }
                tmp[j * W + i] = s / Float(2 * r + 1)
            }
        }
        for j in 0..<H {
            for i in 0..<W {
                var s: Float = 0, n: Float = 0
                for d in -r...r where j + d >= 0 && j + d < H { s += tmp[(j + d) * W + i]; n += 1 }
                out[j * W + i] = s / n
            }
        }
        return out
    }

    // MARK: files and images

    private static func download(_ url: URL) -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue("DeepField", forHTTPHeaderField: "User-Agent")
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        for attempt in 0..<3 {
            URLSession.shared.dataTask(with: request) { data, response, _ in
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { result = data }
                done.signal()
            }.resume()
            done.wait()
            if result != nil { break }
            Thread.sleep(forTimeInterval: Double(attempt + 1))
        }
        return result
    }

    private static func decodeRGBA(_ data: Data, _ W: Int, _ H: Int) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: W * H * 4)
        // exact colors matter (they're looked up in the colormap), so no color management
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        return ok ? px : nil
    }

    private static func grayImage(_ px: [UInt8], _ W: Int, _ H: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func writeGray(_ v: [Float], _ W: Int, _ H: Int, to url: URL) {
        let px = v.map { UInt8(min(max($0, 0), 1) * 255 + 0.5) }
        guard let image = Self.grayImage(px, W, H) else { return }
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }

    private func readGray(_ url: URL) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              image.width == Self.mapWidth, image.height == Self.mapHeight else { return nil }
        var px = [UInt8](repeating: 0, count: Self.mapWidth * Self.mapHeight)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: Self.mapWidth, height: Self.mapHeight, bitsPerComponent: 8,
                                      bytesPerRow: Self.mapWidth, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: Self.mapWidth, height: Self.mapHeight))
            return true
        }
        return ok ? px : nil
    }
}
