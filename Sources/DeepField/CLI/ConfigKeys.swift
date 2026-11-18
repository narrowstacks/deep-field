import Foundation

struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Settings by key for the command line. Keys are the saved format's (WallpaperConfig's Codable
/// keys), and nested values take a dotted path (`palette.core`). Colors read and write as hex.
enum ConfigKeys {
    static func object(_ c: WallpaperConfig) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(c),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict
    }

    static func value(at path: [String], in dict: [String: Any]) -> Any? {
        var current: Any? = dict
        for p in path { current = (current as? [String: Any])?[p] }
        return current
    }

    static func setting(_ value: Any, at path: [String], in dict: [String: Any]) -> [String: Any] {
        var d = dict
        guard let first = path.first else { return d }
        d[first] = path.count == 1 ? value : setting(value, at: Array(path.dropFirst()), in: d[first] as? [String: Any] ?? [:])
        return d
    }

    // MARK: value types

    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func isColor(_ v: Any?) -> Bool {
        guard let d = v as? [String: Any], d.count == 3 else { return false }
        return ["r", "g", "b"].allSatisfy { d[$0] is NSNumber }
    }

    static func hex(_ d: [String: Any]) -> String {
        func byte(_ k: String) -> Int { Int((((d[k] as? NSNumber)?.doubleValue ?? 0) * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02x%02x%02x", byte("r"), byte("g"), byte("b"))
    }

    /// `#rgb`, `#rrggbb` or the same without `#`.
    static func color(fromHex s: String) -> [String: Any]? {
        var h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        func c(_ shift: UInt32) -> Double { (Double((v >> shift) & 0xff) / 255 * 1000).rounded() / 1000 }
        return ["r": c(16), "g": c(8), "b": c(0)]
    }

    /// Readable value: colors as hex, scalars bare, everything else compact JSON.
    static func display(_ v: Any) -> String {
        if isColor(v), let d = v as? [String: Any] { return hex(d) }
        if isBool(v) { return (v as! NSNumber).boolValue ? "true" : "false" }
        if let n = v as? NSNumber { return number(n.doubleValue) }
        if let s = v as? String { return s }
        return json(v, pretty: false)
    }

    static func number(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
    }

    static func json(_ v: Any, pretty: Bool) -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: opts) else { return "\(v)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: keys

    /// Every settable key path: top-level keys, plus `palette.<color>` and the like for nested
    /// objects. Per-scene image storage is managed by the scene switch, so it's left out.
    static func allPaths(_ c: WallpaperConfig = WallpaperConfig()) -> [String] {
        var out: [String] = []
        for (key, value) in object(c) where !internalKeys.contains(key) {
            if let nested = value as? [String: Any], !isColor(nested) {
                out += nested.keys.map { "\(key).\($0)" }
            } else {
                out.append(key)
            }
        }
        return out.sorted()
    }

    static let internalKeys: Set<String> = ["sceneImage", "sharedImage", "phoneFraming", "tdeCycleMinutes"]
    static let imageKeys = ["saturation", "brightness", "contrast", "blackPoint", "highlights", "vignette",
                            "bloom", "bloomRadius", "bloomThreshold", "pixelSize", "levels", "dither"]

    /// The allowed values of an enum-valued key, found by reflection (property names are the
    /// Codable keys).
    static func choices(for key: String) -> [String]? {
        guard let child = Mirror(reflecting: WallpaperConfig()).children.first(where: { $0.label == key }),
              let iterable = child.value as? any CaseIterable else { return nil }
        func cases<T: CaseIterable>(_ v: T) -> [Any] { Array(T.allCases) }
        let raw = cases(iterable).compactMap { ($0 as? any RawRepresentable)?.rawValue as? String }
        return raw.isEmpty ? nil : raw
    }

    static func suggestions(for key: String, in paths: [String]) -> [String] {
        let k = key.lowercased()
        let contains = paths.filter { $0.lowercased().contains(k) || k.contains($0.lowercased()) }
        if !contains.isEmpty { return Array(contains.prefix(5)) }
        return Array(paths.map { ($0, editDistance($0.lowercased(), k)) }.filter { $0.1 <= 3 }
            .sorted { $0.1 < $1.1 }.prefix(5).map(\.0))
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    // MARK: assignments

    struct Assignment {
        let key: String
        let raw: String
        var path: [String] { key.split(separator: ".").map(String.init) }
    }

    static func isAssignment(_ arg: String) -> Bool {
        guard let eq = arg.firstIndex(of: "="), eq != arg.startIndex else { return false }
        return !arg.hasPrefix("-")
    }

    static func assignments(_ args: [String]) throws -> [Assignment] {
        try args.map { arg in
            guard isAssignment(arg), let eq = arg.firstIndex(of: "=") else {
                throw CLIError("expected KEY=VALUE, got \u{201C}\(arg)\u{201D}")
            }
            return Assignment(key: String(arg[..<eq]), raw: String(arg[arg.index(after: eq)...]))
        }
    }

    /// The raw text as the JSON type the key already holds.
    static func parse(_ raw: String, like current: Any, key: String) throws -> Any {
        if isColor(current) {
            if let c = color(fromHex: raw) { return c }
            if let d = jsonValue(raw) as? [String: Any], isColor(d) { return d }
            throw CLIError("\(key) is a color: use hex like #ff8a3d")
        }
        if isBool(current) {
            switch raw.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: throw CLIError("\(key) is on or off: use true or false")
            }
        }
        if current is NSNumber {
            guard let x = Double(raw), x.isFinite else { throw CLIError("\(key) is a number, got \u{201C}\(raw)\u{201D}") }
            return x
        }
        if current is String {
            if let s = jsonValue(raw) as? String { return s }
            return raw
        }
        guard let v = jsonValue(raw) else { throw CLIError("\(key) takes JSON, like \(json(current, pretty: false))") }
        return v
    }

    private static func jsonValue(_ raw: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
    }

    /// `config` with the assignments applied. `scene` goes through the scene switch, so the new
    /// scene brings its own image settings; everything else merges into the saved format and is
    /// decoded with the same lenient decoder as the saved settings. A value that decoder rejects
    /// is an error, one it clamps is a warning.
    static func apply(_ list: [Assignment], to config: WallpaperConfig,
                      listedScenesOnly: Bool = true) throws -> (config: WallpaperConfig, warnings: [String]) {
        var base = config
        var rest: [Assignment] = []
        for a in list {
            if a.key == "scene" {
                base.scene = try SceneKind.named(a.raw, listedOnly: listedScenesOnly)
            } else {
                rest.append(a)
            }
        }
        guard !rest.isEmpty else { return (base, []) }
        let paths = allPaths(base)
        var dict = object(base)
        var wanted: [(Assignment, Any)] = []
        for a in rest {
            guard !internalKeys.contains(a.path[0]), let current = value(at: a.path, in: dict) else {
                let near = suggestions(for: a.key, in: paths)
                throw CLIError("unknown setting \u{201C}\(a.key)\u{201D}" +
                               (near.isEmpty ? "" : " (did you mean \(near.joined(separator: ", "))?)") +
                               "\n`deepfield keys --all` lists them")
            }
            let v = try parse(a.raw, like: current, key: a.key)
            dict = setting(v, at: a.path, in: dict)
            wanted.append((a, v))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let decoded = WallpaperConfig.decode(data) else { throw CLIError("those settings don't decode") }
        let after = object(decoded)
        var warnings: [String] = []
        for (a, v) in wanted {
            let got = value(at: a.path, in: after)
            if same(v, got) { continue }
            if v is String || isColor(v) || isBool(v) || got == nil {
                var msg = "\u{201C}\(a.raw)\u{201D} isn't a valid value for \(a.key)"
                if let c = choices(for: a.key) { msg += " (choose from \(c.joined(separator: ", ")))" }
                throw CLIError(msg)
            }
            warnings.append("\(a.key) was clamped to \(got.map(display) ?? "?")")
        }
        return (decoded, warnings)
    }

    private static func same(_ a: Any, _ b: Any?) -> Bool {
        guard let b else { return false }
        if let x = a as? NSNumber, let y = b as? NSNumber, !isBool(a), !isBool(b) {
            return abs(x.doubleValue - y.doubleValue) <= 1e-6 * max(1, abs(x.doubleValue))
        }
        return json(a, pretty: false) == json(b, pretty: false)
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

extension SceneKind {
    /// A scene by id or title, ignoring case, spaces and punctuation ("ringed-planet", "Star
    /// Close-up"). `random` picks a listed scene other than `current`.
    static func named(_ name: String, listedOnly: Bool = true, current: SceneKind? = nil) throws -> SceneKind {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let n = norm(name)
        if n == "random" || n == "shuffle" {
            return SceneKind.listed.filter { $0 != current }.randomElement() ?? .blackHole
        }
        let pool = listedOnly ? SceneKind.listed : SceneKind.allCases
        if let k = pool.first(where: { norm($0.rawValue) == n || norm($0.title) == n }) { return k }
        let near = pool.filter { norm($0.rawValue).contains(n) || norm($0.title).contains(n) }
        if near.count == 1 { return near[0] }
        throw CLIError("no scene called \u{201C}\(name)\u{201D}" +
                       (near.isEmpty ? "; `deepfield scenes` lists them" : " (did you mean \(near.map(\.rawValue).joined(separator: ", "))?)"))
    }
}

/// Presets by name: the user's saved presets first, then the palette presets, then the
/// scene's own color presets; or a `.deepfield` file.
enum PresetLookup {
    static func apply(_ name: String, to c: inout WallpaperConfig, cwd: String) throws {
        let path = resolve(name, cwd: cwd)
        if name.hasSuffix(".\(PresetStore.fileExtension)") || name.hasSuffix(".json") || FileManager.default.fileExists(atPath: path) {
            c = try file(path).applied(over: c)
            return
        }
        if let p = PresetStore.shared.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            c = p.applied(over: c)
            return
        }
        if let p = PaletteConfig.presets.first(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) {
            c.palette = p.1
            return
        }
        if let p = ColorPreset.all(for: c.scene).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            p.apply(to: &c)
            return
        }
        throw CLIError("no preset called \u{201C}\(name)\u{201D}; `deepfield presets` lists them")
    }

    static func file(_ path: String) throws -> UserPreset {
        guard let data = FileManager.default.contents(atPath: path) else { throw CLIError("can't read \(path)") }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p = PresetStore.preset(from: dict) else { throw CLIError("\(path) isn't a Deep Field preset") }
        return p
    }

    static func resolve(_ path: String, cwd: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? p : (cwd as NSString).appendingPathComponent(p)
    }
}
