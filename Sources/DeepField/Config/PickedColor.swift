import simd

/// Turns a color picked in the Customize window into the light a shader draws with, so the
/// element reads as that color on screen.
///
/// A pick is the sRGB color the element should show where it's typically lit. The shaders work
/// in linear light that `finalize` exposes, tone maps (1 - e^-x), saturates and gamma encodes,
/// so a pick fed in directly came out darker, duller and shifted (a pastel pink read as mauve).
/// `light` runs that chain backwards at the default exposure and saturation, then divides by the
/// element's typical brightness in its shader (`level`). The Exposure and Saturation controls
/// still act on top, as they do on everything else.
///
/// The tuned default colors were written as shader light; `pick(forLight:)` runs the chain
/// forwards to express them as picks, so the defaults still render as they did.
enum PickedColor {
    /// The default look the compensation aims at (WallpaperConfig's brightness and saturation).
    static let exposure: Float = 1.15
    static let saturation: Float = 1.35
    /// The brightest tone-mapped value a pick asks for; 1 would need infinite light.
    static let maxTone: Float = 0.985

    private static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    static func light(_ pick: RGB, level: Float) -> SIMD3<Float> {
        let srgb = simd_clamp(SIMD3(pick.r, pick.g, pick.b), SIMD3(repeating: 0), SIMD3(repeating: 1))
        let t = SIMD3(pow(srgb.x, 2.2), pow(srgb.y, 2.2), pow(srgb.z, 2.2))
        let luma = simd_dot(t, lumaWeights)
        let c = simd_clamp(luma + (t - luma) / saturation, SIMD3(repeating: 0), SIMD3(repeating: maxTone))
        let x = SIMD3(-log(1 - c.x), -log(1 - c.y), -log(1 - c.z)) / exposure
        return x / level
    }

    static func pick(forLight v: RGB, level: Float) -> RGB {
        let x = SIMD3(v.r, v.g, v.b) * level * exposure
        let c = SIMD3(1 - exp(-x.x), 1 - exp(-x.y), 1 - exp(-x.z))
        let luma = simd_dot(c, lumaWeights)
        let s = simd_clamp(luma + (c - luma) * saturation, SIMD3(repeating: 0), SIMD3(repeating: 1))
        func enc(_ v: Float) -> Float { (pow(v, 1 / 2.2) * 1000).rounded() / 1000 }
        return RGB(enc(s.x), enc(s.y), enc(s.z))
    }

    /// Typical brightness of each element in its shader, per unit of color: measured by
    /// rendering gray picks and fitting the light that reproduces the lightness of the region
    /// where the element dominates (the photon ring is too thin to measure; it uses 1).
    enum Level {
        static let diskReceding: Float = 0.52
        static let diskApproaching: Float = 0.8
        static let diskCore: Float = 0.85
        static let ring: Float = 1.0
        static let galaxyCore: Float = 0.36
        static let galaxyArms: Float = 0.47
        static let galaxyNebula: Float = 0.61
        static let pulsarBeam: Float = 0.79
        static let pulsarField: Float = 0.44
        static let pulsarRing: Float = 0.64
        static let pulsarNebula: Float = 0.34
        static let cometIon: Float = 0.36
        static let cometDust: Float = 0.29
        static let tdeJet: Float = 0.45
        static let planetaryInner: Float = 0.5
        static let planetaryRim: Float = 0.6
        static let planetaryHalo: Float = 0.25
        static let ringedBand: Float = 0.75
        static let ringedRing: Float = 0.6
        static let aurora: Float = 0.6
        static let auroraCity: Float = 0.5
        static let gasCloud: Float = 0.75
        static let protoDust: Float = 0.6
        static let protoGas: Float = 0.5
        static let protoStar: Float = 1.0
        static let protoJet: Float = 0.5
        static let mergerStar: Float = 0.8
        static let mergerKilonova: Float = 0.6
        static let dysonPanel: Float = 0.3
        static let dysonHeat: Float = 0.1
        static let rogueAurora: Float = 0.5
        static let rogueRift: Float = 0.5
        static let eclipseCorona: Float = 1.0
        static let eclipseProminence: Float = 1.0
        static let eclipseGround: Float = 1.0
        static let eclipsePlanet: Float = 1.0
    }
}

extension RGB {
    /// The shader light for this picked color at an element's typical brightness.
    func light(_ level: Float) -> SIMD4<Float> { SIMD4(light3(level), 0) }
    func light3(_ level: Float) -> SIMD3<Float> { PickedColor.light(self, level: level) }
    /// A tuned shader light value, expressed as the pick that reproduces it.
    func asPick(_ level: Float) -> RGB { PickedColor.pick(forLight: self, level: level) }
}

extension WallpaperConfig {
    /// The per-scene colors as they were tuned, in shader light; the defaults are their picks.
    enum Tuned: String, CaseIterable {
        case tdeJet = "tdeJetColor", pulsarBeam = "pulsarBeamColor", pulsarNebula = "pulsarNebulaColor"
        case pulsarField = "pulsarFieldColor", pulsarRing = "pulsarRingColor"
        case cometIon = "cometIonColor", cometDust = "cometDustColor"
        case planetaryInner = "planetaryInnerColor", planetaryRim = "planetaryRimColor", planetaryHalo = "planetaryHaloColor"
        case ringedBandLight = "ringedBandLight", ringedBandDark = "ringedBandDark", ringedRing = "ringedRingColor"
        case auroraGreen, auroraRed, auroraFringe, auroraCity = "auroraCityColor"
        case gasZone, gasBelt, gasStorm
        case protoDust = "protoDustColor", protoGas = "protoGasColor", protoStar = "protoStarColor", protoJet = "protoJetColor"
        case mergerStar = "mergerStarColor", mergerHot, mergerCool
        case dysonPanelA, dysonPanelB, dysonHeat
        case rogueAuroraLow, rogueAuroraHigh, rogueRift = "rogueRiftColor"
        case eclipseCorona, eclipseProminence, eclipseGround, eclipsePlanet

        var light: RGB {
            switch self {
            case .tdeJet: RGB(0.6, 0.5, 1.0)
            case .pulsarBeam: RGB(0.55, 0.75, 1.0)
            case .pulsarNebula: RGB(0.7, 0.4, 1.0)
            case .pulsarField: RGB(0.45, 0.68, 1.0)
            case .pulsarRing: RGB(1.0, 0.6, 0.36)
            case .cometIon: RGB(0.3, 0.6, 1.0)
            case .cometDust: RGB(1.0, 0.85, 0.6)
            case .planetaryInner: RGB(0.25, 0.8, 1.0)
            case .planetaryRim: RGB(1.0, 0.3, 0.24)
            case .planetaryHalo: RGB(1.0, 0.35, 0.45)
            case .ringedBandLight: RGB(1.0, 0.76, 0.38)
            case .ringedBandDark: RGB(0.6, 0.26, 0.07)
            case .ringedRing: RGB(1.0, 0.82, 0.55)
            case .auroraGreen: RGB(0.1, 1.0, 0.35)
            case .auroraRed: RGB(1.0, 0.08, 0.4)
            case .auroraFringe: RGB(1.0, 0.2, 0.85)
            case .auroraCity: RGB(1.0, 0.62, 0.28)
            case .gasZone: RGB(1.0, 0.82, 0.58)
            case .gasBelt: RGB(0.62, 0.24, 0.08)
            case .gasStorm: RGB(0.9, 0.24, 0.08)
            case .protoDust: RGB(1.0, 0.45, 0.12)
            case .protoGas: RGB(0.55, 0.62, 1.0)
            case .protoStar: RGB(1.0, 0.85, 0.65)
            case .protoJet: RGB(1.0, 0.25, 0.45)
            case .mergerStar: RGB(0.42, 0.68, 1.0)
            case .mergerHot: RGB(0.3, 0.58, 1.0)
            case .mergerCool: RGB(1.0, 0.2, 0.06)
            case .dysonPanelA: RGB(1.0, 0.62, 0.18)
            case .dysonPanelB: RGB(0.3, 0.38, 1.0)
            case .dysonHeat: RGB(1.0, 0.16, 0.1)
            case .rogueAuroraLow: RGB(0.1, 1.0, 0.55)
            case .rogueAuroraHigh: RGB(0.75, 0.15, 1.0)
            case .rogueRift: RGB(1.0, 0.32, 0.06)
            case .eclipseCorona: RGB(0.5, 0.62, 1.0)
            case .eclipseProminence: RGB(1.0, 0.16, 0.42)
            case .eclipseGround: RGB(0.62, 0.58, 0.54)
            case .eclipsePlanet: RGB(0.3, 0.7, 0.85)
            }
        }

        var level: Float {
            typealias L = PickedColor.Level
            return switch self {
            case .tdeJet: L.tdeJet
            case .pulsarBeam: L.pulsarBeam
            case .pulsarNebula: L.pulsarNebula
            case .pulsarField: L.pulsarField
            case .pulsarRing: L.pulsarRing
            case .cometIon: L.cometIon
            case .cometDust: L.cometDust
            case .planetaryInner: L.planetaryInner
            case .planetaryRim: L.planetaryRim
            case .planetaryHalo: L.planetaryHalo
            case .ringedBandLight, .ringedBandDark: L.ringedBand
            case .ringedRing: L.ringedRing
            case .auroraGreen, .auroraRed, .auroraFringe: L.aurora
            case .auroraCity: L.auroraCity
            case .gasZone, .gasBelt, .gasStorm: L.gasCloud
            case .protoDust: L.protoDust
            case .protoGas: L.protoGas
            case .protoStar: L.protoStar
            case .protoJet: L.protoJet
            case .mergerStar: L.mergerStar
            case .mergerHot, .mergerCool: L.mergerKilonova
            case .dysonPanelA, .dysonPanelB: L.dysonPanel
            case .dysonHeat: L.dysonHeat
            case .rogueAuroraLow, .rogueAuroraHigh: L.rogueAurora
            case .rogueRift: L.rogueRift
            case .eclipseCorona: L.eclipseCorona
            case .eclipseProminence: L.eclipseProminence
            case .eclipseGround: L.eclipseGround
            case .eclipsePlanet: L.eclipsePlanet
            }
        }

        var color: RGB { light.asPick(level) }
    }

    /// Settings saved before colors were picks hold the tuned shader light for any default or
    /// preset color. Those become the matching picks, so they keep looking the same; any other
    /// saved color was picked by hand and now shows as picked.
    static func migrateTunedColors(_ saved: inout [String: Any]) {
        func rgb(_ v: Any?) -> SIMD3<Double>? {
            guard let d = v as? [String: Any], let r = d["r"] as? Double, let g = d["g"] as? Double,
                  let b = d["b"] as? Double else { return nil }
            return SIMD3(r, g, b)
        }
        func same(_ a: SIMD3<Double>, _ c: RGB) -> Bool {
            simd_reduce_max(simd_abs(a - SIMD3(Double(c.r), Double(c.g), Double(c.b)))) < 1e-5
        }
        func dict(_ c: RGB) -> [String: Any] { ["r": Double(c.r), "g": Double(c.g), "b": Double(c.b)] }
        for t in Tuned.allCases {
            if let v = rgb(saved[t.rawValue]), same(v, t.light) { saved[t.rawValue] = dict(t.color) }
        }
        guard var palette = saved["palette"] as? [String: Any] else { return }
        let names: [WritableKeyPath<PaletteConfig, RGB>: String] = [
            \.receding: "receding", \.approaching: "approaching", \.core: "core", \.ring: "ring",
            \.galaxyCore: "galaxyCore", \.galaxyArms: "galaxyArms", \.galaxyNebula: "galaxyNebula",
        ]
        for (kp, level) in PaletteConfig.picked {
            guard let name = names[kp], let v = rgb(palette[name]),
                  let tuned = PaletteConfig.tunedPresets.first(where: { same(v, $0.1[keyPath: kp]) }) else { continue }
            palette[name] = dict(tuned.1[keyPath: kp].asPick(level))
        }
        saved["palette"] = palette
    }
}
