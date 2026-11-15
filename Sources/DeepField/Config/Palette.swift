import AppKit

struct RGB: Codable, Equatable {
    var r: Float, g: Float, b: Float
    init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    var simd: SIMD4<Float> { SIMD4(r, g, b, 1) }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }
}

struct PaletteConfig: Codable, Equatable {
    var receding: RGB       // disk side moving away (redshifted)
    var approaching: RGB    // disk side moving toward you (blueshifted)
    var core: RGB           // hottest inner disk
    var ring: RGB           // photon ring / wormhole rim
    var nebulaA: RGB
    var nebulaB: RGB
    var farA: RGB           // wormhole's other universe
    var farB: RGB
    var starWarm: RGB
    var starCool: RGB
    var galaxy: RGB
    // galaxy scene
    var galaxyCore = RGB(1.0, 0.80, 0.52)      // old stars: bulge and smooth disk
    var galaxyArms = RGB(0.55, 0.72, 1.0)      // young blue stars in the arms
    var galaxyNebula = RGB(1.0, 0.35, 0.6)     // star-forming (H II) regions
    var galaxyDust = RGB(0.12, 0.05, 0.02)     // dust lanes

    private static let gargantuaLight = PaletteConfig(
        receding: RGB(1.0, 0.36, 0.02), approaching: RGB(0.25, 0.5, 1.0), core: RGB(1.0, 0.78, 0.45),
        ring: RGB(0.6, 0.75, 1.0), nebulaA: RGB(0.1, 0.3, 1.0), nebulaB: RGB(1.0, 0.33, 0.17),
        farA: RGB(0.85, 0.35, 1.0), farB: RGB(0.15, 0.85, 0.85),
        starWarm: RGB(1.0, 0.72, 0.45), starCool: RGB(0.55, 0.72, 1.0), galaxy: RGB(1.0, 0.85, 0.7))

    private static let emberLight = PaletteConfig(
        receding: RGB(1.0, 0.12, 0.02), approaching: RGB(1.0, 0.7, 0.15), core: RGB(1.0, 0.92, 0.65),
        ring: RGB(1.0, 0.55, 0.25), nebulaA: RGB(0.7, 0.1, 0.05), nebulaB: RGB(1.0, 0.5, 0.1),
        farA: RGB(1.0, 0.3, 0.1), farB: RGB(1.0, 0.8, 0.3),
        starWarm: RGB(1.0, 0.6, 0.35), starCool: RGB(1.0, 0.85, 0.6), galaxy: RGB(1.0, 0.7, 0.4))

    private static let glacierLight = PaletteConfig(
        receding: RGB(0.15, 0.45, 1.0), approaching: RGB(0.6, 1.0, 1.0), core: RGB(0.92, 0.98, 1.0),
        ring: RGB(0.8, 0.95, 1.0), nebulaA: RGB(0.1, 0.4, 1.0), nebulaB: RGB(0.4, 0.9, 1.0),
        farA: RGB(0.3, 0.6, 1.0), farB: RGB(0.7, 1.0, 0.9),
        starWarm: RGB(0.8, 0.9, 1.0), starCool: RGB(0.5, 0.75, 1.0), galaxy: RGB(0.8, 0.9, 1.0))

    private static let synthwaveLight = PaletteConfig(
        receding: RGB(1.0, 0.1, 0.55), approaching: RGB(0.1, 0.85, 1.0), core: RGB(1.0, 0.85, 1.0),
        ring: RGB(1.0, 0.45, 1.0), nebulaA: RGB(0.55, 0.1, 1.0), nebulaB: RGB(1.0, 0.2, 0.6),
        farA: RGB(1.0, 0.2, 0.7), farB: RGB(0.2, 1.0, 0.9),
        starWarm: RGB(1.0, 0.55, 0.9), starCool: RGB(0.5, 0.9, 1.0), galaxy: RGB(1.0, 0.6, 1.0))

    private static let amberCRTLight = PaletteConfig(
        receding: RGB(1.0, 0.45, 0.0), approaching: RGB(1.0, 0.7, 0.15), core: RGB(1.0, 0.85, 0.5),
        ring: RGB(1.0, 0.7, 0.3), nebulaA: RGB(1.0, 0.5, 0.0), nebulaB: RGB(1.0, 0.6, 0.1),
        farA: RGB(1.0, 0.55, 0.05), farB: RGB(1.0, 0.75, 0.3),
        starWarm: RGB(1.0, 0.65, 0.2), starCool: RGB(1.0, 0.8, 0.45), galaxy: RGB(1.0, 0.7, 0.3))

    private static let emeraldLight = PaletteConfig(
        receding: RGB(0.05, 0.8, 0.3), approaching: RGB(0.4, 0.6, 1.0), core: RGB(0.85, 1.0, 0.8),
        ring: RGB(0.6, 1.0, 0.8), nebulaA: RGB(0.05, 0.6, 0.4), nebulaB: RGB(0.3, 0.3, 1.0),
        farA: RGB(0.9, 0.9, 0.2), farB: RGB(0.2, 0.9, 0.5),
        starWarm: RGB(0.85, 1.0, 0.7), starCool: RGB(0.6, 0.8, 1.0), galaxy: RGB(0.8, 1.0, 0.8))

    /// The presets as tuned, in shader light (see PickedColor).
    static let tunedPresets: [(String, PaletteConfig)] = [
        ("Gargantua", gargantuaLight), ("Ember", emberLight), ("Glacier", glacierLight),
        ("Synthwave", synthwaveLight), ("Amber CRT", amberCRTLight), ("Emerald", emeraldLight),
    ]
    static let presets = tunedPresets.map { ($0.0, $0.1.fromLight()) }
    static let gargantua = presets[0].1

    /// The colors that are picks (the swatch is what the element shows), with each one's
    /// typical brightness. The rest (the faint background sky, galaxy dust) are tints, used as is.
    static let picked: [(WritableKeyPath<PaletteConfig, RGB>, Float)] = [
        (\.receding, PickedColor.Level.diskReceding), (\.approaching, PickedColor.Level.diskApproaching),
        (\.core, PickedColor.Level.diskCore), (\.ring, PickedColor.Level.ring),
        (\.galaxyCore, PickedColor.Level.galaxyCore), (\.galaxyArms, PickedColor.Level.galaxyArms),
        (\.galaxyNebula, PickedColor.Level.galaxyNebula),
    ]

    /// A palette written as shader light, with its picked colors converted to picks.
    func fromLight() -> PaletteConfig {
        var p = self
        for (kp, level) in Self.picked { p[keyPath: kp] = self[keyPath: kp].asPick(level) }
        return p
    }
}
