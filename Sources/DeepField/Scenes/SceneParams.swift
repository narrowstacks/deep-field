import Foundation
import simd

private extension RGB {
    var v4: SIMD4<Float> { SIMD4(r, g, b, 0) }
}

/// Builds the per-frame `SceneParamsGPU` slots for the scenes whose state is computed on the CPU.
enum SceneParams {
    static func build(_ c: WallpaperConfig, elapsed t: Double, camera cam: Camera,
                      width: Int, height: Int, events: EventSchedule,
                      demo: [UInt64: Double] = ConfigStore.shared.demoEvents) -> SceneParamsGPU {
        switch c.scene {
        case .tidalDisruption: return tidalDisruption(c)
        case .pulsar: return pulsar(c, t, cam)
        case .nebula: return nebula(c)
        case .planetaryNebula: return planetaryNebula(c, t, cam, events, demo)
        case .ringedPlanet: return ringedPlanet(c, t, cam, events, demo)
        case .auroraOrbit: return auroraOrbit(c, t, cam, events, demo)
        case .liveEarth: return liveEarth(c, t, cam, width: width, height: height)
        case .gasGiant: return gasGiant(c, t, cam, events, demo)
        case .protoplanetaryDisk: return protoplanetaryDisk(c, t, cam, events, demo)
        case .neutronMerger: return neutronMerger(c, t, cam, demo)
        case .blackHoleMerger: return blackHoleMerger(c, t, cam, demo)
        case .dysonSwarm: return dysonSwarm(c, t, cam, events, demo)
        case .roguePlanet: return roguePlanet(c, t, cam, events, demo)
        case .eclipse: return eclipse(c, t, cam, events, demo)
        case .comet: return comet(c, t, cam, events, demo)
        case .stellarSurface: return stellarSurface(c, t, cam, events, demo)
        case .quasar: return quasar(c, t, cam, events, demo)
        default: return SceneParamsGPU()
        }
    }

    // MARK: Pulsar

    private static func pulsar(_ c: WallpaperConfig, _ t: Double, _ cam: Camera) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let tilt = c.pulsarAxisTilt / 180 * .pi
        // spin axis: up, leaning toward the camera
        let spin = simd_normalize(SIMD3(0, cos(tilt), -sin(tilt)))
        let e1 = simd_normalize(simd_cross(spin, SIMD3(1, 0, 0)))
        let e2 = simd_cross(spin, e1)
        let phase = (t / max(c.pulsarPeriod, 0.2)).truncatingRemainder(dividingBy: 1) * 2 * .pi
        let alpha = c.pulsarInclination / 180 * .pi
        let m = cos(alpha) * spin + sin(alpha) * (cos(phase) * e1 + sin(phase) * e2)
        let width = c.pulsarBeamWidth / 180 * .pi
        // The beams wind back behind the rotation (radians per unit of length), more so the
        // faster it spins, like water from a turning hose.
        let trail = min(0.08 / max(c.pulsarPeriod, 0.2), 0.12) * c.pulsarBeamTrail
        // lighthouse flash when a beam sweeps across the camera; the part of the beam that
        // reaches us left the star a while ago, so use its wound-back direction
        let toCam = simd_normalize(cam.pos)
        let lag = -trail * simd_length(cam.pos)
        let mc = cos(lag) * m + sin(lag) * simd_cross(spin, m) + (1 - cos(lag)) * simd_dot(spin, m) * spin
        let beams = c.pulsarBeams.mask
        let toward = simd_dot(mc, toCam)
        let facing = toward >= 0 ? 1 : 2           // which beam points our way
        let ang = acos(min(abs(toward), 1))
        let flash = beams & facing != 0 ? exp(-pow(ang / (width * 2), 2)) : 0
        typealias L = PickedColor.Level
        func scaled(_ col: RGB, _ level: Float, _ k: Double, _ on: Bool = true) -> SIMD3<Float> {
            on ? col.light3(level) * Float(max(k, 0)) : .zero
        }
        p.a = SIMD4(SIMD3<Float>(m), Float(width))
        p.b = SIMD4(SIMD3<Float>(spin), Float(flash))
        p.c = SIMD4(scaled(c.pulsarBeamColor, L.pulsarBeam, c.pulsarBeamIntensity), Float(beams))
        p.d = SIMD4(scaled(c.pulsarNebulaColor, L.pulsarNebula, c.pulsarNebulaIntensity, c.pulsarNebula),
                    !c.pulsarFieldLines ? 0 : c.pulsarFieldStyle == .lines ? 1 : 2)
        p.e = SIMD4(scaled(c.pulsarFieldColor, L.pulsarField, c.pulsarFieldIntensity), Float(trail))
        p.f = SIMD4(scaled(c.pulsarRingColor, L.pulsarRing, c.pulsarRingIntensity, c.pulsarRing), 0)
        return p
    }

    // MARK: Nebula

    private static func nebula(_ c: WallpaperConfig) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        p.a = SIMD4(Float(60 / max(c.nebulaFlow, 0.05)), 1, 0, 0)
        p.b = c.nebulaHa.v4
        p.c = c.nebulaOIII.v4
        p.d = c.nebulaSII.v4
        return p
    }

    // MARK: Planetary nebula

    private static func planetaryNebula(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                        _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        // the barrel's axis: tipped away from our line of sight toward the upper right
        let view = cam.center
        let lean = c.planetaryView / 180 * .pi, turn = 0.6
        let side = cos(turn) * cam.right + sin(turn) * cam.up
        let axis = simd_normalize(cos(lean) * view + sin(lean) * side)
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(axis), Float(3.5 * c.planetarySize))
        p.b = SIMD4(c.planetaryInnerColor.light3(L.planetaryInner), Float(c.planetaryElongation))
        p.c = SIMD4(c.planetaryRimColor.light3(L.planetaryRim), Float(c.planetaryKnots))
        p.d = SIMD4(c.planetaryHaloColor.light3(L.planetaryHalo), c.planetaryHalo ? 1 : 0)
        p.e.y = 3.7
        var star = 1.0
        if case (let age, _)? = events.active(EventSchedule.shellEjection, rate: c.planetaryEvents.rate, at: t, demo: demo) {
            let f = age / EventSchedule.shellEjection.duration
            // the star flares as it lets go, then the shell coasts outward, slowing and thinning
            star += 2.5 * smoothstep(0, 0.02, f) * exp(-f / 0.06)
            p.e.z = Float(0.06 + 0.9 * (1 - exp(-f * 2.2)))
            p.e.w = Float(smoothstep(0, 0.04, f) * (1 - smoothstep(0.55, 1, f)) * (1.4 - 0.8 * f))
        }
        p.f = SIMD4(0.75, 0.88, 1.0, Float(star))
        return p
    }

    // MARK: Ringed planet

    private static func ringedPlanet(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                     _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let toCam = -cam.center
        // the spin axis: screen up, tipped toward us to open the rings, then slanted
        let open = c.ringedTilt / 180 * .pi
        let axis0 = simd_normalize(cos(open) * cam.up + sin(open) * toCam)
        let axis = simd_normalize(simd_quatd(angle: c.ringedRoll / 180 * .pi, axis: toCam).act(axis0))
        // The sun, set against the ring plane: `ringedSun` degrees round from us (off to the
        // right), `ringedSunHeight` degrees above the plane. Lower than our own view of the rings,
        // their shadow falls across the side of the planet we see.
        let phase = c.ringedSun / 180 * .pi, height = c.ringedSunHeight / 180 * .pi
        let c1 = simd_normalize(toCam - axis * simd_dot(toCam, axis))
        var c2 = simd_cross(axis, c1)
        if simd_dot(c2, cam.right) < 0 { c2 = -c2 }
        let sun = simd_normalize(cos(height) * (cos(phase) * c1 + sin(phase) * c2) + sin(height) * axis)
        let R = 4.4 * c.ringedSize
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(axis), Float(R))
        p.b = SIMD4(SIMD3<Float>(sun), 1.05)
        p.c = SIMD4(c.ringedBandLight.light3(L.ringedBand), 0)
        p.d = SIMD4(c.ringedBandDark.light3(L.ringedBand), 0)
        p.e = SIMD4(c.ringedRingColor.light3(L.ringedRing), 0)
        p.i = SIMD4(Float(c.ringedBands), Float(c.ringedTurbulence), Float(c.ringedWind), 0)
        p.j = SIMD4(c.ringedRingStyle.shaderIndex, Float(c.ringedRingWidth), Float(c.ringedRingDensity), c.ringedSpokes ? 1 : 0)

        // Up to three moons outside the rings. e1 points our way in the ring plane. The inner moon's
        // orbit is tipped so its near side rises across the face of the planet, casting its shadow
        // on the clouds as it goes.
        let e1 = simd_normalize(simd_cross(axis, cam.right)), e2 = simd_cross(axis, e1)
        let moons = [(orbit: 2.75, period: 7.0, radius: 0.045, phase: 1.3, tip: 14.5),
                     (orbit: 3.9, period: 16.0, radius: 0.075, phase: 4.1, tip: -3.0),
                     (orbit: 5.3, period: 34.0, radius: 0.06, phase: 2.4, tip: 7.0)]
        for (i, m) in moons.prefix(c.ringedMoonCount).enumerated() {
            let a = m.phase + 2 * .pi * t * c.ringedMoonSpeed / (m.period * 60)
            let tip = m.tip / 180 * .pi
            let pos = R * m.orbit * (cos(a) * (cos(tip) * e1 + sin(tip) * axis) + sin(a) * e2)
            let v = SIMD4(SIMD3<Float>(pos), Float(R * m.radius * c.ringedMoonSize))
            switch i {
            case 0: p.f = v
            case 1: p.g = v
            default: p.h = v
            }
        }

        // A great white storm breaks out in one band and spreads round the planet. It's drawn in
        // the bands' drifting frame (see rgDrift in the shader): it appears facing us and then
        // rides the band.
        if case (let age, var rng)? = events.active(EventSchedule.whiteStorm, rate: c.ringedEvents.rate, at: t, demo: demo) {
            let lat = 0.52
            let wrap = Double(SceneGeometry.flowPeriod) * 1000
            let start = (t - age).truncatingRemainder(dividingBy: wrap)
            let drift = start * c.ringedWind * (0.0025 + 0.004 * cos(lat * 19))
            let view = simd_normalize(toCam - axis * simd_dot(toCam, axis))
            let lonView = atan2(simd_dot(view, e2), simd_dot(view, e1))
            p.c.w = Float(lonView + drift + rng.range(-0.5, 0.3))
            p.d.w = Float(max(age / EventSchedule.whiteStorm.duration, 0.001))
        }
        return p
    }

    // MARK: Aurora from orbit

    private static func auroraOrbit(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                    _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let h = c.auroraAltitude / 6371
        // pitch down so the limb's top sits at `auroraHorizon` on screen: it lies `dip` below
        // the horizontal, and the screen height v is atan(v * tanHalf) from the view's center
        let dip = acos(1 / (1 + h))
        let pitch = -dip - atan(c.auroraHorizon * cam.tanHalf)
        let deg = Double.pi / 180
        var sub = 0.0
        if case (let age, _)? = events.active(EventSchedule.substorm, rate: c.auroraEvents.rate, at: t, demo: demo) {
            let f = age / EventSchedule.substorm.duration
            sub = smoothstep(0, 0.08, f) * (1 - smoothstep(0.45, 1, f))
        }
        typealias L = PickedColor.Level
        p.a = SIMD4(Float(pitch), Float(h), Float(c.auroraDistance * deg), Float(c.auroraOvalSize * deg))
        p.b = SIMD4(c.auroraGreen.light3(L.aurora), Float(c.auroraBrightness))
        p.c = SIMD4(c.auroraRed.light3(L.aurora), Float(c.auroraActivity))
        p.d = SIMD4(c.auroraFringe.light3(L.aurora), Float(sub))
        p.e = SIMD4(c.auroraCityColor.light3(L.auroraCity), Float(c.auroraCityLights))
        // Earth turns eastward under the view, about four times its real rate by default, so a
        // full turn takes under six hours. The view starts over Europe and heads west from there.
        let spin = 0.0003 * c.auroraDrift
        let lon = (10 * deg - spin * t).remainder(dividingBy: 2 * .pi)
        p.f = SIMD4(Float(c.auroraClouds), Float(c.auroraMoonlight), Float(spin), Float(c.auroraLightning.rate))
        // z: whether the real Earth maps are bound (the renderer sets it), w: the view's longitude
        p.g = SIMD4(Float(c.auroraSunrise), 5.3, 0, Float(lon))
        return p
    }

    // MARK: Live Earth

    /// Dev only (`--earth-timelapse`): Earth seconds per second of the scene's clock, 0 for real time.
    static var earthTimeLapse = 0.0

    /// The moment Live Earth shows: now, or the time it's frozen at.
    static func liveEarthDate(_ c: WallpaperConfig, elapsed t: Double = 0) -> Date {
        let base = c.earthFreezeTime ? Date(timeIntervalSince1970: c.earthFrozenTime) : Date()
        return base.addingTimeInterval(earthTimeLapse * t)
    }

    /// Live Earth's planets for the shader (buffer 8), in its Earth-fixed frame, from the frame's
    /// scene parameters: the sky turn in rows k, l, m, the camera at a, the Moon at f. A label
    /// shows only while its planet isn't behind Earth or the Moon.
    static func liveEarthPlanets(_ c: WallpaperConfig, elapsed t: Double, _ p: SceneParamsGPU) -> [SkyPlanetGPU] {
        guard c.earthPlanets else { return [] }
        let rows = [p.k, p.l, p.m].map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        // the rows take Earth-fixed to J2000; their transpose takes J2000 back
        func toScene(_ j: SIMD3<Double>) -> SIMD3<Double> { rows[0] * j.x + rows[1] * j.y + rows[2] * j.z }
        let cam = SIMD3<Double>(Double(p.a.x), Double(p.a.y), Double(p.a.z))
        let moon = SIMD3<Double>(Double(p.f.x), Double(p.f.y), Double(p.f.z)), moonR = Double(p.f.w)
        func clear(_ dir: SIMD3<Double>) -> Bool {
            func blocked(_ center: SIMD3<Double>, _ r: Double) -> Bool {
                let oc = cam - center, b = simd_dot(oc, dir)
                return b < 0 && simd_length_squared(oc) - b * b < r * r
            }
            return !blocked(.zero, 1.02) && !blocked(moon, moonR)
        }
        return SkyPlanets.gpu(SkyPlanets.planets(liveEarthDate(c, elapsed: t)), toScene: toScene, labelVisible: clear)
    }

    /// Where the planets' labels go, for Renderer.encodeLabels: each name's left edge and vertical
    /// center in target pixels, which name, and the font's pixel size. Found by projecting each
    /// planet through the same camera the frame was drawn with (Camera.ray, run backward from
    /// the scene's view turn in b, c, d). The font is scaled to look about the same size on
    /// screen at any pixel size.
    static func liveEarthLabels(_ c: WallpaperConfig, _ planets: [SkyPlanetGPU], _ p: SceneParamsGPU,
                                camera cam: Camera, width: Int, height: Int) -> [SIMD4<Float>] {
        guard c.earthPlanetLabels else { return [] }
        let font = max(1, (3.0 / Double(max(c.pixelSize, 1))).rounded())
        let pixelAngle = 2 * cam.tanHalf / Double(height)
        let axes = [p.b, p.c, p.d].map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        let placed: [SIMD4<Float>] = planets.compactMap { pl in
            guard pl.light.w > 0.5 else { return nil }
            let w = SIMD3<Double>(Double(pl.dir.x), Double(pl.dir.y), Double(pl.dir.z))
            let l = SIMD3(simd_dot(w, axes[0]), simd_dot(w, axes[1]), simd_dot(w, axes[2]))
            guard l.z > 0 else { return nil }
            let rx = l.x / l.z / cam.tanHalf, ry = l.y / l.z / cam.tanHalf
            let x = cos(cam.roll) * rx + sin(cam.roll) * ry, y = -sin(cam.roll) * rx + cos(cam.roll) * ry
            let px = (x / cam.aspect + 1) / 2 * Double(width), py = (1 - y) / 2 * Double(height)
            guard px > -10, px < Double(width), py > -10, py < Double(height) + 10 else { return nil }
            // clear of the planet's drawn disk (and Saturn's rings)
            let saturn = pl.pole.w == 4
            let drawn = Double(pl.dir.w) * c.earthPlanetSize * (saturn ? 2.3 : 1) / pixelAngle
            let left = px + max(drawn, 1) + 2 * font
            return SIMD4(Float(left.rounded()), Float(py.rounded()), pl.pole.w, Float(font))
        }
        // Planets close together in the sky (Mars passing Jupiter) would print their names over
        // each other: going down the screen, move a label below any earlier one it would hit.
        let lineHeight = Float(9 * font), widthPerChar = Float(6 * font)
        var out: [SIMD4<Float>] = []
        for var l in placed.sorted(by: { $0.y < $1.y }) {
            let width = Float(SkyPlanets.names[Int(l.z)].count) * widthPerChar
            for o in out {
                let ow = Float(SkyPlanets.names[Int(o.z)].count) * widthPerChar
                if l.x < o.x + ow && o.x < l.x + width && abs(l.y - o.y) < lineHeight { l.y = o.y + lineHeight }
            }
            out.append(l)
        }
        return out
    }

    private static func liveEarth(_ c: WallpaperConfig, _ t: Double, _ cam: Camera, width: Int, height: Int) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let date = liveEarthDate(c, elapsed: t)
        let home = Astronomy.point(latitude: c.homeLatitude, longitude: c.homeLongitude)
        let pos = home * c.earthDistance
        // looking straight down at the chosen place with north up: east is on the right
        let fwd = -home
        var north = SIMD3<Double>(0, 0, 1) - home * home.z
        if simd_length(north) < 1e-6 { north = SIMD3(-1, 0, 0) - home * home.x }   // at a pole
        let up = simd_normalize(north)
        let right = simd_cross(fwd, up)
        // turn the view so Earth's center lands where the settings put it on screen
        let aspect = Double(width) / Double(max(height, 1))
        let toCenter = simd_normalize(SIMD3(c.earthCenterX * cam.tanHalf * aspect, c.earthCenterY * cam.tanHalf, 1))
        let q = simd_quatd(from: toCenter, to: SIMD3(0, 0, 1))
        func world(_ v: SIMD3<Double>) -> SIMD4<Float> {
            let r = q.act(v)
            return SIMD4(SIMD3<Float>(r.x * right + r.y * up + r.z * fwd), 0)
        }
        let sun = Astronomy.sun(date)
        let moon = Astronomy.moon(date)
        let moonRadius = 1737.4 / 6371.0
        let night = simd_dot(home, sun) < 0
        p.a = SIMD4(SIMD3<Float>(pos), 0)
        p.b = world(SIMD3(1, 0, 0))
        p.c = world(SIMD3(0, 1, 0))
        p.d = world(SIMD3(0, 0, 1))
        p.e = SIMD4(SIMD3<Float>(sun), c.earthHideSunAtNight && night ? 0 : 1)
        p.f = SIMD4(SIMD3<Float>(moon), Float(moonRadius * c.earthMoonSize))
        p.g = SIMD4(Float(c.earthClouds ? c.earthCloudAmount : 0), Float(c.earthAurora ? c.earthAuroraBrightness : 0),
                    Float(c.earthCityLights), Float(c.earthMoonlight))
        // x, y, z: which maps are bound (the renderer sets them); w: the season, 0 mid-January to
        // 1 mid-July, blending the two surface maps so snow comes and goes
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let dayOfYear = Double(utc.ordinality(of: .day, in: .year, for: date) ?? 1)
        p.h = SIMD4(0, 0, 0, Float(0.5 - 0.5 * cos(2 * .pi * (dayOfYear - 15) / 365.25)))
        p.i = SIMD4(SIMD3<Float>(home), c.earthMarker ? 1 : 0)
        // z: whether the star maps are bound (the renderer sets it)
        // w: the Moon is close enough to the sun for its shadow to touch Earth (within about 1.3
        // degrees seen from Earth's center, allowing for the parallax of Earth's radius), so the
        // shader only works out the shadow during a solar eclipse
        let sunMoon = acos(min(max(simd_dot(sun, simd_normalize(moon)), -1), 1))
        let eclipse = sunMoon < asin(1 / simd_length(moon)) + 0.012
        p.j = SIMD4(Float(c.earthAtmosphere), Float(moonRadius), 0, eclipse ? 1 : 0)
        // the turn from Earth-fixed directions to the stars' catalog frame (J2000), rows in k, l, m
        let sky = Astronomy.earthFixedToJ2000(date)
        p.k = SIMD4(SIMD3<Float>(sky[0]), 0)
        p.l = SIMD4(SIMD3<Float>(sky[1]), 0)
        p.m = SIMD4(SIMD3<Float>(sky[2]), 0)
        p.n = SIMD4(Float(c.earthStars), Float(c.earthMilkyWay), Float(c.earthAuroraSpeed), 0)
        // the planets: how many are bound (the renderer sets it), their size, labels on
        p.o = SIMD4(0, Float(c.earthPlanetSize), c.earthPlanetLabels ? 1 : 0, 0)
        return p
    }

    // MARK: Gas giant storms

    /// Wind speed at latitude sine `sl`, radians of longitude per second; mirrors ggWind.
    private static func gasWind(_ sl: Double, _ wind: Double) -> Double {
        wind * 0.0025 * (0.75 * sin(sl * 21) + 0.35 * cos(sl * 8) + 0.25)
    }

    private static func gasGiant(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                 _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        // the scene's own frame: camera at the origin, looking down +z
        let R = 1.0
        let aim = simd_normalize(SIMD3(c.gasCenterX * cam.aspect * cam.tanHalf, c.gasCenterY * cam.tanHalf, 1))
        let center = aim * c.gasDistance * R
        let lean = c.gasTilt / 180 * .pi
        let axis = simd_normalize(SIMD3(sin(lean), cos(lean), -0.22))
        let phase = c.gasSun / 180 * .pi
        let sun = simd_normalize(cos(phase) * SIMD3(0, 0, -1) + sin(phase) * simd_normalize(SIMD3(-0.95, 0.3, 0)))
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(center), Float(R))
        p.b = SIMD4(SIMD3<Float>(axis), Float(c.gasWind))
        p.c = SIMD4(SIMD3<Float>(sun), Float(c.gasTurbulence))
        p.d = SIMD4(c.gasZone.light3(L.gasCloud), Float(c.gasStormSize))
        p.e = SIMD4(c.gasBelt.light3(L.gasCloud), 40)
        p.f = SIMD4(c.gasStorm.light3(L.gasCloud), Float(c.gasLightning.rate))
        p.i.x = 4.3
        let towardUs = SIMD3<Double>(0, 0, -1)
        let e1 = simd_normalize(towardUs - axis * simd_dot(towardUs, axis)), e2 = simd_cross(axis, e1)
        if c.gasMoon {
            // a small moon whose orbit carries it across the face of the planet
            let a = 0.9 + 2 * .pi * t / (6 * 60)
            let tip = 8.0 / 180 * .pi
            let pos = center + 2.1 * R * (cos(a) * (cos(tip) * e1 + sin(tip) * axis) + sin(a) * e2)
            p.g = SIMD4(SIMD3<Float>(pos), Float(0.045 * R))
        }
        if case (let age, var rng)? = events.active(EventSchedule.cometImpact, rate: c.gasEvents.rate, at: t, demo: demo) {
            // a fragment train hits a band on the side facing us
            let sl = 0.47, lon = rng.range(-0.5, 0.1)
            let cl = (1 - sl * sl).squareRoot()
            let site = axis * sl + (e1 * cos(lon) + e2 * sin(lon)) * cl
            p.h = SIMD4(SIMD3<Float>(site), Float(max(age / EventSchedule.cometImpact.duration, 0.0005)))
        }
        return p
    }

    // MARK: Protoplanetary disk

    /// An accretion outburst's light curve, `a` seconds after it starts: a soft-edged flash, then a
    /// long faint glow. Mirrors pdOutburst in the shader, which uses it for the light echo.
    static func protoOutburst(_ a: Double) -> Double {
        a <= 0 ? 0 : exp(-(a - 9) * (a - 9) / 25) + 0.12 * smoothstep(0, 12, a) * exp(-a / 45)
    }

    private static func protoplanetaryDisk(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                           _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        // the disk's axis: tipped from our line of sight toward screen up (so the far side shows
        // above the star), then slanted
        let toCam = -cam.center
        let incl = c.protoView / 180 * .pi, slant = c.protoSlant / 180 * .pi
        let side = cos(slant) * cam.up + sin(slant) * cam.right
        let axis = simd_normalize(cos(incl) * toCam + sin(incl) * side)
        let e1 = simd_normalize(simd_cross(side, toCam) - axis * simd_dot(simd_cross(side, toCam), axis))
        let R = 8.5 * c.protoSize
        let w = c.protoLook.weights
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(axis), Float(R))
        p.b = SIMD4(SIMD3<Float>(e1), Float(0.05 + 0.065 * c.protoFlaring))
        p.c = SIMD4(c.protoDustColor.light3(L.protoDust), Float(c.protoGapWidth))
        p.d = SIMD4(c.protoGasColor.light3(L.protoGas), w.x)
        p.f = SIMD4(c.protoJetColor.light3(L.protoJet), c.protoJets ? 1 : 0)
        // the outer edge orbits in 10 minutes at speed 1; the inner rings far faster (Kepler)
        p.g = SIMD4(Float(c.protoGaps), 2.3, Float(2 * .pi / 600 * c.protoOrbitSpeed), 90)
        p.h = SIMD4(-1, Float(R / 35), 6, 0)
        p.i = SIMD4(w.y, w.z, 0, 0)
        var star = 1.0
        if case (let age, _)? = events.active(EventSchedule.accretionOutburst, rate: c.protoEvents.rate, at: t, demo: demo) {
            // FU Orionis style: the inner disk dumps onto the star, which flares; the flash then
            // travels out across the disk as a light echo (the shader delays it by path length)
            p.h.x = Float(age)
            star += Double(p.h.z) * protoOutburst(age)
        }
        p.e = SIMD4(c.protoStarColor.light3(L.protoStar), Float(star))
        return p
    }

    // MARK: Neutron star merger

    /// Seconds before the merger that a demo (the merger event) starts from.
    static let mergerLead = 12.0

    /// The merger cycle at time t. Each cycle starts with a merger (u = 0) and ends with the next
    /// one: the kilonova fades over the first `post` seconds into a lingering nebula around the
    /// remnant, a companion falls in from beyond the frame when tau (the time left before the
    /// next merger) reaches `tauA`, its orbit is round by `tauC`, and the chirp runs from there.
    /// A demo jumps to a few seconds before a merger and carries on from there.
    struct MergerClock {
        let u: Double, cycle: Double, index: Double
        var post: Double { min(70, cycle * 0.3) }
        var tau: Double { cycle - u }
        var tauA: Double { cycle * 0.62 }
        var tauC: Double { cycle * 0.22 }
    }

    static func mergerClock(_ c: WallpaperConfig, _ t: Double, demo: [UInt64: Double]) -> MergerClock {
        cycleClock(minutes: c.mergerCycleMinutes, t, demoStart: demo[EventSchedule.neutronMerger.id])
    }

    private static func cycleClock(minutes: Double, _ t: Double, demoStart: Double?) -> MergerClock {
        let cycle = max(minutes * 60, 120)
        var u = t + cycle * 0.3              // so a launch opens on the remnant, not a flash
        if let s = demoStart, t >= s {
            u = cycle - mergerLead + (t - s)
        }
        let index = floor(u / cycle)
        return MergerClock(u: u - index * cycle, cycle: cycle, index: index)
    }

    /// A captured companion's inspiral: the chirp's constant K (orbital phase phi0 - K tau^(5/8)
    /// once the orbit is circular), its separation A tau^(1/4), and the captured orbit's
    /// semi-major axis (its apoapsis lies beyond the frame) and eccentricity.
    struct Inspiral {
        let K: Double, A: Double, capA: Double, capE: Double
        /// Eccentricity kept through the chirp (0 rounds the orbit out), shed only at the end.
        var eccEnd = 0.0
    }

    private static let neutronInspiral = Inspiral(K: 4.5, A: 1.55, capA: 14.5, capE: 0.8)

    /// The companion's orbit relative to the remnant at time-to-merger tau: semi-major axis and
    /// eccentricity. Gravitational waves shrink and circularize it; by tauC it has joined the
    /// circular chirp, whose separation goes as tau^(1/4).
    private static func mergerOrbit(_ tau: Double, _ k: MergerClock, _ s: Inspiral) -> (a: Double, e: Double) {
        let w = smoothstep(k.tauC, k.tauA, tau)
        let chirp = s.A * pow(max(tau, 0), 0.25)
        return (chirp + (s.capA - chirp) * w, s.capE * w + (1 - w) * s.eccEnd * smoothstep(0.3, 4, tau))
    }

    /// Mean anomaly at tau: pi (apoapsis) at tauA, then advanced at the Kepler rate for the
    /// shrinking orbit (omega^2 a^3 fixed, matching the chirp), in closed form once it's circular.
    private static func mergerMeanAnomaly(_ tau: Double, _ k: MergerClock, _ s: Inspiral) -> Double {
        func rate(_ x: Double) -> Double { 0.625 * s.K * pow(mergerOrbit(x, k, s).a / s.A, -1.5) }
        let lo = max(tau, k.tauC), hi = k.tauA
        var m = Double.pi
        if hi > lo {
            // Simpson's rule
            let steps = 160, h = (hi - lo) / Double(steps)
            var s = rate(lo) + rate(hi)
            for i in 1..<steps { s += rate(lo + Double(i) * h) * (i % 2 == 1 ? 4 : 2) }
            m += s * h / 3
        }
        if tau < k.tauC { m += s.K * (pow(k.tauC, 0.625) - pow(max(tau, 0), 0.625)) }
        return m
    }

    /// Where the periapsis points in cycle `index`: companions come in from alternate sides.
    private static func mergerPeriapsis(_ index: Double) -> Double {
        (index.truncatingRemainder(dividingBy: 2) == 0 ? 0 : .pi) + 0.35 * sin(index * 1.7)
    }

    private static func neutronMerger(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                      _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let k = mergerClock(c, t, demo: demo)
        let u = k.u, tau = k.tau
        // the orbit axis leans away from our line of sight, up and a little to the side
        let view = c.mergerView / 180 * .pi
        let toCam = simd_normalize(cam.pos)
        let lean = simd_normalize(cos(0.25) * cam.up + sin(0.25) * cam.right)
        let n = simd_normalize(cos(view) * toCam + sin(view) * lean)
        let e1 = simd_normalize(cam.right - n * simd_dot(cam.right, n))
        let e2 = simd_cross(n, e1)
        let s = neutronInspiral, K = s.K
        // the circular chirp's phase constant for this cycle's pair, and for the last one
        let mC = mergerMeanAnomaly(k.tauC, k, s) + K * pow(k.tauC, 0.625)
        let phi0Next = mC + mergerPeriapsis(k.index), phi0Last = mC + mergerPeriapsis(k.index - 1)

        // The companion: falls in from apoapsis beyond the frame at tauA, swings close past the
        // remnant, and is worn down into the chirp. Its position comes from Kepler's equation.
        var rel = SIMD3<Double>(0, 0, 0)
        var presence = 0.0, stretch = 1.0
        if tau < k.tauA {
            let (a, e) = mergerOrbit(tau, k, s)
            let m = mergerMeanAnomaly(tau, k, s)
            var E = m + e * sin(m)
            for _ in 0..<12 { E -= (E - e * sin(E) - m) / (1 - e * cos(E)) }
            let r = a * (1 - e * cos(E))
            let nu = 2 * atan2(sqrt(1 + e) * sin(E / 2), sqrt(1 - e) * cos(E / 2))
            let ang = nu + mergerPeriapsis(k.index)
            rel = (cos(ang) * e1 + sin(ang) * e2) * r
            presence = smoothstep(k.tauA, k.tauA - 4, tau)
            // tides stretch each star toward the other in the last moments
            stretch = 1 + 0.9 * pow(min(2.6 * 0.2 / max(r, 1e-3), 1), 3)
        }
        // The pair's balance point: the remnant stays put while the companion is far and
        // light on it, and the two share the orbit equally as it tightens (equal masses).
        let share = 0.5 * (1 - smoothstep(k.tauC, k.tauA, tau))
        let cA = -rel * share, cB = rel * (1 - share)

        // each star's magnetic axis turns with its spin
        func magnetic(_ incl: Double, _ period: Double, _ offset: Double) -> SIMD3<Double> {
            let w = 2 * .pi * t / period + offset
            return cos(incl) * n + sin(incl) * (cos(w) * e1 + sin(w) * e2)
        }
        // The remnant is a magnetar: a slow beat in its glow and field, and a spin-down
        // brightening just after it forms. The beat quiets once it has a partner.
        let beat = pow(0.5 + 0.5 * sin(2 * .pi * t / 5.0), 3)
        let remGlow = 1 + 0.6 * beat * (1 - 0.6 * presence) + 1.2 * exp(-u / 25)
        // the kilonova: bright, then a lingering nebula that dims as the next merger nears
        let kfade = (1 - 0.7 * smoothstep(k.post * 0.5, k.post, u)) * (1 - 0.4 * smoothstep(0.8 * k.cycle, k.cycle, u))
        let flash = exp(-u / 0.3)
        // waves: those still to arrive from the coming merger, or those spreading from the last
        let tauW = u < k.cycle / 2 ? -u : tau
        let phi0 = (tauW < 0 ? phi0Last : phi0Next).truncatingRemainder(dividingBy: 2 * .pi)
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(cA), Float(remGlow))
        p.b = SIMD4(SIMD3<Float>(cB), Float(stretch))
        p.c = SIMD4(SIMD3<Float>(n), Float(c.mergerWaves))
        p.d = SIMD4(SIMD3<Float>(e1), Float(tauW))
        p.e = SIMD4(c.mergerStarColor.light3(L.mergerStar) * Float(c.mergerBrightness), Float(presence))
        p.f = SIMD4(c.mergerHot.light3(L.mergerKilonova), Float(u))
        p.g = SIMD4(c.mergerCool.light3(L.mergerKilonova), Float(kfade))
        p.h = SIMD4(SIMD3<Float>(magnetic(0.6, 1.7, 0)), c.mergerJet ? 1 : 0)
        p.i = SIMD4(SIMD3<Float>(magnetic(0.85, 2.6, 2)), Float(c.mergerGlow))
        p.j = SIMD4(Float(K), Float(phi0), Float(k.tauC), Float(flash))
        return p
    }

    // MARK: Black hole merger

    /// The black hole merger's cycle, laid out like the neutron star merger's.
    /// The scene's own speed: every motion in it, the merger cycle included, runs this much faster.
    static func bbhSpeed(_ c: WallpaperConfig) -> Double { min(max(c.bbhSpeed, 0.1), 4) }

    static func bbhClock(_ c: WallpaperConfig, _ t: Double, demo: [UInt64: Double]) -> MergerClock {
        let v = bbhSpeed(c)
        let k = cycleClock(minutes: c.bbhCycleMinutes, t * v, demoStart: demo[EventSchedule.blackHoleMerger.id].map { $0 * v })
        // Slow motion round the merger: the last second of the chirp and the ringdown play
        // `slow` times slower, easing in and out, and the rest of the cycle runs a little
        // shorter to make room. x is the time from the nearest merger, negative before it; the
        // speed is 1 - (1 - 1/slow) times a smooth bump over the window, whose integral is a
        // difference of softplus terms.
        let slow = min(max(c.bbhRingdown, 1), 8)
        guard slow > 1.001 else { return k }
        let before = 1.0 * slow, after = 1.6 * slow, soft = 1.0
        func softplus(_ v: Double) -> Double { v > 30 ? v : log(1 + exp(v)) }
        func h(_ x: Double) -> Double { soft * (softplus((x + before) / soft) - softplus((x - after) / soft)) }
        func warp(_ x: Double) -> Double { x - (1 - 1 / slow) * (h(x) - h(0)) }
        let half = k.cycle / 2
        let cycle = warp(half) - warp(-half)
        let u = k.u < half ? warp(k.u) : cycle + warp(k.u - k.cycle)
        return MergerClock(u: u, cycle: cycle, index: k.index)
    }

    /// The pair's chirp for mass ratio q, with the heavier hole's mass M setting the scale. With
    /// eta the symmetric mass ratio, the phase left before the merger goes as eta^(-3/8) tau^(5/8)
    /// and the separation as M (eta tau)^(1/4), so an unequal pair is tighter and winds through
    /// more orbits in the same time.
    private static func bbhInspiral(_ q: Double, _ M: Double, eccentric: Bool) -> Inspiral {
        let eta4 = 4 * q / ((1 + q) * (1 + q))
        return Inspiral(K: 4.5 * pow(eta4, -0.375), A: 2.6 * pow(eta4, 0.25) * M, capA: 24, capE: 0.8,
                        eccEnd: eccentric ? 0.55 : 0)
    }

    /// The remnant of holes of mass m1 and m2: their sum less the energy the waves carried off,
    /// about 5% for an equal pair and less for unequal ones.
    private static func bbhRemnant(_ m1: Double, _ m2: Double) -> Double {
        let eta4 = 4 * m1 * m2 / ((m1 + m2) * (m1 + m2))
        return (m1 + m2) * (1 - 0.048 * eta4 * eta4)
    }

    /// Generations in a hierarchical chain: each remnant becomes the heavy partner of the next
    /// merger, three times over, before the scene starts afresh.
    private static let bbhGenerations = 3

    /// How far the recoil kick throws the remnant, in scene units. Unequal masses beam the waves
    /// unevenly (Gonzalez et al. 2007: at most about 175 km/s, near a 1 to 3 pair); spins tilted
    /// into the orbital plane, which also drive precession, can add thousands of km/s.
    private static func bbhKick(_ c: WallpaperConfig, _ q: Double) -> Double {
        let eta = q / ((1 + q) * (1 + q))
        let vm = 12000 * eta * eta * sqrt(max(1 - 4 * eta, 0)) * (1 - 0.93 * eta)
        let v = vm / 175 + 1.5 * min(max(c.bbhPrecession, 0), 1)
        return min(max(c.bbhKick, 0) * v * 1.8, 7)
    }

    private static func blackHoleMerger(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                        _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let k = bbhClock(c, t, demo: demo)
        let u = k.u, tau = k.tau
        let q0 = min(max(c.bbhMassRatio, 0.05), 1)
        let model = c.bbhModel

        // In a chain the waiting hole is the last remnant, so each new companion is relatively
        // lighter. Masses are in units of the first heavy hole.
        func gen(_ index: Double) -> Int {
            guard c.bbhChain else { return 0 }
            let n = Double(bbhGenerations)
            return Int(index - n * floor(index / n))
        }
        func heavy(_ g: Int) -> Double { (0..<g).reduce(1.0) { m, _ in bbhRemnant(m, q0) } }
        let G = gen(k.index), M = heavy(G)
        let mPrev = heavy(gen(k.index - 1)), peak = bbhRemnant(mPrev, q0)
        let q = q0 / M
        let s = bbhInspiral(q, M, eccentric: c.bbhEccentric), K = s.K
        let eta4 = 4 * q / ((1 + q) * (1 + q))

        // The total angular momentum J leans away from our line of sight by the viewing angle.
        // Spins tilted off it make the orbit precess around J, faster as the orbit tightens: the
        // precession rate goes as the orbital frequency to the 5/3, so its phase as tau^(3/8).
        let view = c.bbhView / 180 * .pi
        let toCam = simd_normalize(cam.pos)
        let lean = simd_normalize(cos(0.25) * cam.up + sin(0.25) * cam.right)
        let J = simd_normalize(cos(view) * toCam + sin(view) * lean)
        let ja = simd_normalize(simd_cross(J, cam.right)), jb = simd_cross(J, ja)
        let beta = 0.5 * min(max(c.bbhPrecession, 0), 1)
        // (eased over the last moments, where the rate would otherwise run away and the plane
        // would lurch between frames)
        func normal(_ tau: Double, _ index: Double) -> SIMD3<Double> {
            let ph = index * 2.4 - 2.2 * (pow(max(tau, 0) + 0.3, 0.375) - pow(0.3, 0.375))
            return simd_normalize(cos(beta) * J + sin(beta) * (cos(ph) * ja + sin(ph) * jb))
        }
        let inspiralling = tau < k.tauA
        // the plane of the coming pair's orbit, or, until the companion arrives, of the last one's
        let n = inspiralling ? normal(tau, k.index) : normal(0, k.index - 1)
        let e1 = simd_normalize(cam.right - n * simd_dot(cam.right, n))
        let e2 = simd_cross(n, e1)
        let mC = mergerMeanAnomaly(k.tauC, k, s) + K * pow(k.tauC, 0.625)
        let phi0Next = mC + mergerPeriapsis(k.index), phi0Last = mC + mergerPeriapsis(k.index - 1)
        // An eccentric orbit's periapsis advances each turn, more as it tightens (relativistic
        // apsidal precession), so the path traces a rosette: zoom out, whirl round, zoom out.
        let rosette = c.bbhEccentric ? 0.3 : 0.0

        // The recoil kick: the remnant flies off from where the pair merged and coasts to a
        // stop (slowed for looks), where the next companion finds it. The stops lie on a small
        // circle round the frame's center, a golden angle apart, so it never wanders off.
        let kick = bbhKick(c, q)
        func stop(_ i: Double) -> SIMD3<Double> {
            (cos(2.4 * i) * cam.right + sin(2.4 * i) * cam.up) * (kick / 1.864)
        }
        let coast = min((1 - exp(-u / 10)) / (1 - exp(-6.0)), 1)
        let from = stop(k.index - 1), to = stop(k.index)
        let center = from + (to - from) * coast
        let velocity = (to - from) * (u < 60 ? exp(-u / 10) / (10 * (1 - exp(-6.0))) : 0)

        // The companion, as in the neutron star merger: captured on a wide eccentric orbit and
        // worn down into the chirp.
        let r0 = 0.6
        // The shadows meet before the holes do: the chirp's separation falls to zero at the
        // merger, but what we see joins at contact, a little inside the two shadows' radii. The
        // separation eases onto that contact distance instead of sliding to a point.
        let contact = 0.8 * r0 * (M + q0)
        var rel = SIMD3<Double>(repeating: 0)
        var presence = 0.0, a = 0.0
        var gasAngle = 0.0   // the binary's direction in the orbital plane, for the gas's streams
        if inspiralling {
            let (aa, e) = mergerOrbit(tau, k, s)
            a = aa
            let m = mergerMeanAnomaly(tau, k, s)
            var E = m + e * sin(m)
            for _ in 0..<12 { E -= (E - e * sin(E) - m) / (1 - e * cos(E)) }
            let r = aa * (1 - e * cos(E))
            let nu = 2 * atan2(sqrt(1 + e) * sin(E / 2), sqrt(1 - e) * cos(E / 2))
            let w = smoothstep(k.tauC, k.tauA, tau)
            let ang = nu + mergerPeriapsis(k.index) + rosette * (m - mC) * (1 - w)
            rel = (cos(ang) * e1 + sin(ang) * e2) * pow(pow(r, 4) + pow(contact, 4), 0.25)
            // The gas follows the orbit's mean motion until a second before the merger, then
            // can't keep up (it decouples) and turns on at that rate.
            gasAngle = tau >= 1 ? m + mergerPeriapsis(k.index) : phi0Next - K + 0.625 * K * (1 - tau)
            presence = smoothstep(k.tauA, k.tauA - 4, tau)
        }
        // the heavier hole moves less: each sits opposite the other about their center of mass
        let share = q / (1 + q) * (1 - smoothstep(k.tauC, k.tauA, tau))
        var cA = center - rel * share, cB = center + rel * (1 - share)

        // Shadow sizes go with mass. The remnant swells at the merger; outside a chain (and when
        // a chain starts over) the frame then eases back out until it is the size of the next
        // pair's heavier hole.
        let settle = G == 0 ? smoothstep(0.12 * k.cycle, 0.34 * k.cycle, u) : 0
        let g = (mPrev + (peak - mPrev) * smoothstep(0, 0.8, u)) * (1 - settle) + M * settle
        let lens = 2.4 * max(c.bbhLensing, 0)
        // The remnant bends light with the pair's whole mass from the start (less what the
        // waves carry off during the ringdown), so the lensed sky doesn't jump at the merger.
        let lensMass = (mPrev + q0 + (peak - mPrev - q0) * smoothstep(0, 0.8, u)) * (1 - settle) + M * settle
        // the photon rings brighten through the merger, rising before it and fading after
        let ringBoost = u < k.cycle / 2 ? 1 + 1.2 * exp(-u / 1.5) : 1 + 1.2 * exp(-(tau / 0.6) * (tau / 0.6))

        // Ringdown: the remnant's fundamental quasinormal mode, a little above the pitch the
        // chirp ends on. Faster spin rings higher and for longer (fits from Berti, Cardoso and
        // Will 2006, relative to a 0.69 spin). Remnants deep in a chain spin a little faster.
        let chi = min(max(c.bbhSpin, 0) + 0.05 * Double(gen(k.index - 1)), 0.98)
        let qnmF = 1 - 0.63 * pow(1 - chi, 0.3), qnmQ = 2 * pow(1 - chi, -0.45)
        let ringOmega = 4.65 * K * 1.2 * qnmF / 0.557   // 4.65 K: the chirp's last wave frequency

        // A supermassive pair clears a cavity about twice its orbit in the gas disk. Late in the
        // chirp the orbit shrinks faster than the gas can follow (decoupling), so the cavity
        // stays wide through the merger and then slowly refills, feeding the remnant.
        let aDec = s.A * pow(0.1 * k.tauC, 0.25)
        let cavity: Double
        if inspiralling {
            let open = smoothstep(k.tauA, k.tauA - 40, tau)
            cavity = 1.1 + 1.5 * min(max(a, aDec), 3.5) * open
        } else {
            cavity = 1.1 + 1.5 * min(aDec, 3.5) * (1 - smoothstep(0, 0.25 * k.cycle, u))
        }
        let glow: Double
        if model == .agnDisk {
            // In a quasar's disk the kicked remnant plows through dense gas and lights it up
            // some time later (the flare candidate for GW190521 came about a month after).
            glow = smoothstep(6, 16, u) * exp(-max(u - 16, 0) / 30) * (0.5 + 0.25 * kick)
        } else {
            glow = smoothstep(0.05 * k.cycle, 0.2 * k.cycle, u) * (1 - smoothstep(0.3 * k.cycle, 0.6 * k.cycle, u))
        }
        // The remnant's jets point along its spin, which the merger can flip: the old jets fade
        // while the new ones grow, as in X-shaped radio galaxies.
        let jets = model == .supermassive ? 1.0 : 0.0
        let jetNew = jets * smoothstep(3, 25, u)
        let jetOld = jets * (1 - smoothstep(0, 0.5 * k.cycle, u))
        // A quasar's disk is far wider than the frame and lies at its own tilt; the others are
        // in the plane of the binary's total angular momentum.
        let diskNormal = model == .agnDisk ? simd_normalize(cos(0.9) * toCam + sin(0.9) * cam.up) : J

        // After the merger the pair's two lobes don't vanish at once: they keep turning at the
        // ringdown's pattern speed (half its wave frequency) while they slide together and the
        // light partner's lobe is absorbed, fading over the damping time. That is the spinning
        // peanut, and the shadow and the lensing carry straight on from the moment before.
        var radiusB = inspiralling ? r0 * q0 : 0
        var lensB = lens * sqrt(q0) * presence
        var lensA = lens * sqrt(lensMass)
        var lobes = 1.0      // how far the tidal stretch still shows: 1 for the pair, fading after
        if !inspiralling {
            // and after it the streams' turn winds down over about a second
            gasAngle = phi0Last - K + 0.625 * K * (1 + (1 - exp(-u)))
            let f = exp(-u / (2 * qnmQ / ringOmega))
            if f > 0.003 {
                let qPrev = q0 / mPrev, sharePrev = qPrev / (1 + qPrev)
                let reach = 0.8 * r0 * (mPrev + q0) * f
                let psi = phi0Last + 0.5 * ringOmega * u
                let dir = cos(psi) * e1 + sin(psi) * e2
                cA = center - dir * reach * sharePrev
                cB = center + dir * reach * (1 - sharePrev)
                radiusB = r0 * q0 * sqrt(f)
                let wB = q0 / (mPrev + q0) * f
                lensA = lens * sqrt(lensMass * (1 - wB))
                lensB = lens * sqrt(lensMass * wB)
                lobes = f
            }
        }

        // (decided by the cycle's half, not tauW's sign: at the merger instant tauW is -0)
        let afterMerger = u < k.cycle / 2
        let tauW = afterMerger ? -u : tau
        let phi0 = (afterMerger ? phi0Last : phi0Next).truncatingRemainder(dividingBy: 2 * .pi)
        let peri = (afterMerger ? mergerPeriapsis(k.index - 1) : mergerPeriapsis(k.index)).truncatingRemainder(dividingBy: 2 * .pi)
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(cA), Float(r0 * g))
        p.b = SIMD4(SIMD3<Float>(cB), Float(radiusB))
        p.c = SIMD4(SIMD3<Float>(n), Float(c.bbhWaves * pow(eta4, 0.5)))
        p.d = SIMD4(SIMD3<Float>(e1), Float(tauW))
        // the gas's streams and second mini-disk outlast the companion by a few seconds
        let gasPair = inspiralling ? presence : exp(-u / 4)
        p.e = SIMD4(c.bbhRingColor.light3(L.bbhRing), Float(gasPair))
        p.f = SIMD4(c.bbhHot.light3(L.bbhGas), Float(u))
        p.g = SIMD4(c.bbhCool.light3(L.bbhGas), model.shaderIndex)
        p.h = SIMD4(Float(K), Float(phi0), Float(k.tauC), Float((1 - q) / (1 + q)))
        p.i = SIMD4(Float(lensA), Float(lensB), Float(chi), Float(ringBoost))
        p.j = SIMD4(Float(ringOmega), Float(2 * qnmQ / ringOmega), Float(cavity), Float(glow))
        p.k = SIMD4(SIMD3<Float>(normal(0, k.index - 1)), Float(jetNew))
        p.l = SIMD4(SIMD3<Float>(normal(0, k.index - 2)), Float(jetOld))
        p.m = SIMD4(SIMD3<Float>(diskNormal), Float(gasAngle.truncatingRemainder(dividingBy: 2 * .pi)))
        p.n = SIMD4(Float(peri), Float(s.eccEnd), Float(rosette), Float(lobes))
        p.o = SIMD4(SIMD3<Float>(center), (c.bbhTrace ? 1 : 0) + (c.bbhGalaxy ? 2 : 0))
        // the scene's own clock, for the motions the shader runs on its own (gas, cluster, jets)
        p.p = SIMD4(SIMD3<Float>(velocity), Float((t * bbhSpeed(c)).truncatingRemainder(dividingBy: 100_000)))
        return p
    }

    // MARK: Dyson swarm

    private static func dysonSwarm(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                   _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        // the scene's own frame: camera at the origin, looking down +z; the star is 1 unit across
        let r0 = 1.7, r1 = 4.3
        let aim = simd_normalize(SIMD3(0, cam.subjectY * cam.tanHalf, 1))
        let center = aim * 19
        let rings = min(max(c.dysonRings, 3), 20)
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(center), 1)
        p.b = SIMD4(SIMD3(c.dysonStar.color.r, c.dysonStar.color.g, c.dysonStar.color.b), 4.5)
        // the innermost ring's orbit phase; outer rings scale it by Kepler's law in the shader
        let phase = t * c.dysonOrbitSpeed * 0.012
        p.c = SIMD4(Float(rings), Float(min(max(c.dysonDensity, 0), 1)), Float(c.dysonGlint), Float(phase))
        p.d = SIMD4(c.dysonPanelA.light3(L.dysonPanel), 3.7)
        p.e = SIMD4(c.dysonPanelB.light3(L.dysonPanel), Float(r0))
        p.f = SIMD4(c.dysonHeat.light3(L.dysonHeat), Float(r1))
        if case (let age, var rng)? = events.active(EventSchedule.swarmWave, rate: c.dysonEvents.rate, at: t, demo: demo) {
            // a wave of panels on three neighboring rings in the outer half turns to face us
            let ring = min(Double(rings / 2) + floor(rng.next() * Double(rings / 2)), Double(rings - 3))
            p.g = SIMD4(Float(ring), Float(age), 26, 1)
        }
        return p
    }

    // MARK: Rogue planet

    private static func roguePlanet(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                    _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        // the scene's own frame: camera at the origin, looking down +z; the planet has radius 1
        let th = cam.tanHalf
        // it drifts slowly against the stars, covering and uncovering them as it goes
        let dx = 0.05 * sin(2 * .pi * t / 1300) + 0.02 * sin(2 * .pi * t / 530 + 1.3)
        let dy = 0.03 * sin(2 * .pi * t / 1900 + 0.7)
        let aim = simd_normalize(SIMD3(c.rogueCenterX * cam.aspect * th + dx * th, (c.rogueCenterY + dy) * th, 1))
        let alpha = atan(0.55 * c.rogueSize * th)          // angular radius
        let center = aim / sin(alpha)
        let axis = simd_normalize(SIMD3(-0.32, 0.88, -0.3))
        let spin = 2 * Double.pi * t / 1000 * c.rogueSpin
        // the magnetic axis leans off the spin axis and turns with the planet, so the aurorae wobble
        let towardUs = SIMD3<Double>(0, 0, -1)
        let e1 = simd_normalize(towardUs - axis * simd_dot(towardUs, axis)), e2 = simd_cross(axis, e1)
        let tilt = 14.0 / 180 * .pi
        let mag = cos(tilt) * axis + sin(tilt) * (cos(spin + 0.6) * e1 + sin(spin + 0.6) * e2)
        typealias L = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(center), 1)
        p.b = SIMD4(SIMD3<Float>(axis), Float(spin))
        p.c = SIMD4(SIMD3<Float>(mag), Float(c.rogueAurora))
        p.d = SIMD4(c.rogueAuroraLow.light3(L.rogueAurora), Float(c.rogueRift))
        p.e = SIMD4(c.rogueAuroraHigh.light3(L.rogueAurora), Float(c.rogueMilkyWay))
        p.f = SIMD4(c.rogueRiftColor.light3(L.rogueRift), 5.3)
        // the Milky Way: a great circle from lower left to upper right, its bright center just
        // beside the planet so the planet's thin air scatters its light into a rim
        func dir(_ u: Double, _ v: Double) -> SIMD3<Double> { simd_normalize(SIMD3(u * cam.aspect * th, v * th, 1)) }
        let gc = dir(0.62, 0.2)
        let band = simd_normalize(simd_cross(dir(-1.1, -0.75), gc))
        p.i = SIMD4(SIMD3<Float>(band), 0)
        p.j = SIMD4(SIMD3<Float>(gc), Float(tan(alpha)))
        if c.rogueMoon {
            // a small moon on a tipped orbit that carries it in front of and behind the planet
            let a = 2.2 + 2 * .pi * t / (17 * 60)
            let tip = 0.32
            let ax = simd_normalize(SIMD3(0.15, 1, 0.1))
            let u = simd_normalize(simd_cross(ax, SIMD3(0, 0, 1))), w = simd_cross(u, ax)
            let pos = center + 3.4 * (cos(a) * u + sin(a) * (cos(tip) * w + sin(tip) * ax))
            p.g = SIMD4(SIMD3<Float>(pos), 0.2)
        }
        if case (let age, var rng)? = events.active(EventSchedule.starGlint, rate: c.rogueEvents.rate, at: t, demo: demo) {
            // a bright background star passes behind the planet (in planet radii from its center,
            // on the sky): first a glint on one limb, a ring of light all round when it lines up,
            // then a glint on the far limb
            let u = age / EventSchedule.starGlint.duration
            let ang = rng.range(0, 2 * .pi), miss = rng.range(-0.3, 0.3)
            let along = SIMD2(cos(ang), sin(ang)), across = SIMD2(-sin(ang), cos(ang))
            let pos = across * miss + along * (1.6 - 3.2 * u)
            let fade = min(u / 0.06, 1) * min((1 - u) / 0.06, 1)
            p.h = SIMD4(Float(pos.x), Float(pos.y), Float(fade), Float(rng.range(0, 1)))
        }
        return p
    }

    // MARK: Eclipse

    /// The occluder's limb relief (mountains +, valleys -); mirrors ecLimb in ShaderEclipse.swift.
    static func eclipseLimb(_ a: Double) -> Double {
        let hills = 0.35 * sin(7 * a + 1.3) + 0.2 * sin(13 * a + 0.4) + 0.1 * sin(29 * a + 2.1)
        let n1 = pow(max(sin(11 * a + 0.7), 0), 12), n2 = pow(max(sin(17 * a + 2.9), 0), 12)
        let n3 = pow(max(sin(23 * a + 4.4), 0), 16)
        return hills - 1.3 * (n1 + 0.8 * n2 + 0.7 * n3)
    }
    static let eclipseMount = 0.012
    static let eclipseOccluder = 1.06      // the occluder's radius, in sun radii

    /// The occluder's offset from the sun (sun radii) at cycle phase u: it lingers near the middle,
    /// so totality and the beads either side of it last, then speeds off. a sinh(b (u - 1/2)) runs
    /// from -8 to 8 radii, far enough out that the jump back at the cycle's end isn't seen.
    static func eclipseOffset(_ u: Double) -> SIMD2<Double> {
        let b = 15.2, a = 8 / sinh(b / 2)
        let x = a * sinh(b * (u - 0.5))
        let path = -0.32                  // the path's slant across the sun, radians
        let along = SIMD2(cos(path), sin(path)), across = SIMD2(-sin(path), cos(path))
        return along * x + across * 0.018
    }

    /// The share of the sun left uncovered for offset o, and the middle of that light (sun radii),
    /// integrated round the occluder's (mountainous) limb: along each direction from its center,
    /// the uncovered stretch is from its limb, or where the ray enters the sun, to where it leaves.
    /// A sky body in front of the sun (`body`: its center and radius, sun radii) also hides the
    /// part of each stretch that crosses its disk.
    static func eclipseExposure(_ o: SIMD2<Double>, body: SIMD3<Double>? = nil) -> (fraction: Double, center: SIMD2<Double>) {
        let n = 720
        var area = 0.0, moment = SIMD2<Double>(0, 0)
        let oo = simd_dot(o, o)
        let w = body.map { o - SIMD2($0.x, $0.y) } ?? .zero
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            let u = SIMD2(cos(a), sin(a))
            let b = simd_dot(o, u), disc = b * b - oo + 1
            guard disc > 0 else { continue }
            let t2 = -b + disc.squareRoot(), t1 = max(-b - disc.squareRoot(), 0)
            let t0 = max(t1, eclipseOccluder + eclipseMount * eclipseLimb(a))
            guard t2 > t0 else { continue }
            var a2: Double = (t2 * t2 - t0 * t0) / 2
            var a3: Double = (t2 * t2 * t2 - t0 * t0 * t0) / 3
            if let body {
                let bb = simd_dot(w, u), db = bb * bb - simd_dot(w, w) + body.z * body.z
                if db > 0 {
                    let c0 = max(t0, -bb - db.squareRoot()), c1 = min(t2, -bb + db.squareRoot())
                    if c1 > c0 {
                        a2 -= (c1 * c1 - c0 * c0) / 2
                        a3 -= (c1 * c1 * c1 - c0 * c0 * c0) / 3
                    }
                }
            }
            area += a2
            moment += o * a2 + u * a3
        }
        let da = 2 * Double.pi / Double(n)
        area *= da
        moment *= da
        if area <= 1e-12 { return (0, o) }
        return (min(area / .pi, 1), moment / area)
    }

    /// Where totality starts and ends in the cycle (phase 0..1), found once by bisection.
    static let eclipseTotality: (start: Double, end: Double) = {
        func total(_ u: Double) -> Bool { eclipseExposure(eclipseOffset(u)).fraction <= 0 }
        var lo = 0.2, hi = 0.5
        for _ in 0..<30 { let m = (lo + hi) / 2; if total(m) { hi = m } else { lo = m } }
        let start = hi
        lo = 0.5; hi = 0.8
        for _ in 0..<30 { let m = (lo + hi) / 2; if total(m) { lo = m } else { hi = m } }
        return (start, lo)
    }()

    private static func eclipse(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let s = cam.screenScale
        let th = 0.5
        // The horizon dips 8 degrees (see EC_HEIGHT); pitch the view so it sits low on screen.
        let dip = 8.0 / 180 * .pi
        let horizonV = cam.portrait ? (cam.subjectY - 0.55) * s : -0.42
        let pitch = atan(-horizonV * th) - dip
        // screen position (half screen heights) -> scene direction
        func dir(_ x: Double, _ y: Double) -> SIMD3<Double> {
            let r = simd_normalize(SIMD3(x * th, y * th, 1))
            return SIMD3(r.x, r.y * cos(pitch) + r.z * sin(pitch), -r.y * sin(pitch) + r.z * cos(pitch))
        }
        let sunPos = cam.portrait ? SIMD2(0.05 * s, (cam.subjectY + 0.32) * s) : SIMD2(0.75, 0.3)
        let body = c.eclipseSkyBody
        let planetPos = cam.portrait
            ? SIMD2(c.eclipsePlanetX * 0.9 * s, (cam.subjectY - 0.27 + c.eclipsePlanetY) * s)
            : SIMD2(c.eclipsePlanetX * cam.aspect, c.eclipsePlanetY)
        let sun = dir(sunPos.x, sunPos.y)
        let tanSun = 0.125 * th * s
        p.a = SIMD4(SIMD3<Float>(sun), Float(tanSun))

        // the occluder's pass (or its parked spot), its uncovered light, and the eye's adaptation
        let hold = c.eclipseMotion == .hold
        let cycle = max(c.eclipseCycleMinutes, 0.5) * 60
        let u = hold ? 0.5 : (t / cycle + 0.12).truncatingRemainder(dividingBy: 1)
        let o = eclipseOffset(u)
        // the sky body hides the sun too when it's placed in front of it (it's far beyond our
        // moon's occluder, so its shadow has no parallax across the ground)
        var bodyDisk: SIMD3<Double>? = nil
        if body != .none {
            let pd = dir(planetPos.x, planetPos.y)
            let sx = simd_normalize(simd_cross(SIMD3<Double>(0, 1, 0), sun)), sy = simd_cross(sun, sx)
            let along = simd_dot(pd, sun)
            let tanPlanet = 0.6 * th * s * c.eclipsePlanetSize * body.scale
            if along > 0 {
                let bc = SIMD2(simd_dot(pd, sx), simd_dot(pd, sy)) / along / tanSun
                let br = tanPlanet / tanSun
                if simd_length(bc) < 1 + br { bodyDisk = SIMD3(bc.x, bc.y, br) }
            }
        }
        let exMoon = eclipseExposure(o)
        let ex = bodyDisk == nil ? exMoon : eclipseExposure(o, body: bodyDisk)
        let e = ex.fraction
        // what the body leaves of the light the occluder alone would let through
        let bodyShare = exMoon.fraction > 1e-9 ? e / exMoon.fraction : 1
        let gain = 2.5 / (0.15 + 0.85 * e.squareRoot())
        p.b = SIMD4(Float(o.x), Float(o.y), Float(eclipseOccluder), Float(e))
        p.j = SIMD4(Float(ex.center.x), Float(ex.center.y), Float(gain), Float(log10(max(e, 1e-9))))

        typealias L = PickedColor.Level
        // the ground and sky body colors tint each type's own surface color
        func tint(_ pick: RGB, _ level: Float, _ tuned: WallpaperConfig.Tuned) -> SIMD3<Float> {
            let d = tuned.light
            return simd_clamp(pick.light3(level) / SIMD3(max(d.r, 0.05), max(d.g, 0.05), max(d.b, 0.05)),
                              SIMD3(repeating: 0), SIMD3(repeating: 3))
        }
        p.c = SIMD4(c.eclipseCoronaColor.light3(L.eclipseCorona), Float(c.eclipseCoronaSize))
        p.d = SIMD4(c.eclipseProminenceColor.light3(L.eclipseProminence), Float(c.eclipseProminences))
        p.e = SIMD4(c.eclipseWorld.base * tint(c.eclipseGroundColor, L.eclipseGround, .eclipseGround), c.eclipseLandscape ? 1 : 0)
        var lit = 0.0
        if body != .none {
            let pd = dir(planetPos.x, planetPos.y)
            let tanPlanet = 0.6 * th * s * c.eclipsePlanetSize * body.scale
            p.f = SIMD4(SIMD3<Float>(pd), Float(tanPlanet))
            lit = (1 + simd_dot(sun, -pd)) / 2         // the planet's sunlit share, seen from here
        }
        p.g = SIMD4(body.base * tint(c.eclipsePlanetColor, L.eclipsePlanet, .eclipsePlanet), Float(c.eclipseCoronaBrightness))
        // shadow parallax: the occluder is near enough that its umbra on the ground is only a few
        // horizon-distances across, so the light comes back over the horizon first
        p.i = SIMD4(Float(th), Float(pitch), 0.25, Float(lit))
        if c.eclipseAtmosphere {
            // the sky's color as scattering strength per channel, brightest channel 1
            let a = c.eclipseAirColor
            var lin = SIMD3<Float>(pow(max(a.r, 0.02), 2.2), pow(max(a.g, 0.02), 2.2), pow(max(a.b, 0.02), 2.2))
            lin /= max(lin.max(), 1e-3)
            p.k = SIMD4(lin, Float(max(c.eclipseAirDensity, 0.01)))
        }
        p.l = SIMD4(Float(c.eclipseAirHaze), Float(c.eclipseClouds), body.shaderIndex, c.eclipseWorld.shaderIndex)

        // Eruptions. Cycling, a scheduled window waits for the next totality, so it plays with the
        // corona out. Held at totality there's no waiting, and they come every few minutes.
        // A demo starts at once.
        let k = hold ? EventSchedule.Kind(id: EventSchedule.eclipseEruption.id, slot: 200, chance: 0.75, duration: 150)
                     : EventSchedule.eclipseEruption
        if case (let age, var rng)? = events.active(k, rate: c.eclipseEvents.rate, at: t, demo: demo) {
            let tot = eclipseTotality
            let totLength = (tot.end - tot.start) * cycle
            var start = t - age, length = hold ? k.duration : max(totLength, 60)
            let isDemo = demo[k.id].map { t >= $0 && t - $0 < k.duration } ?? false
            if !isDemo && !hold {
                // the first totality whose middle is still ahead when the window opens
                let phase0 = (start / cycle + 0.12)
                var n = floor(phase0)
                if phase0 - n > (tot.start + tot.end) / 2 { n += 1 }
                start = (n + tot.start - 0.12) * cycle
                length = totLength
            }
            let f = (t - start) / length
            if f >= 0, f < 1 {
                // leave the sun upward or sideways, into open sky; held, anywhere off the horizon
                let ang = hold ? rng.range(-0.4, 3.5) : rng.range(0.9, 2.6)
                let bright = smoothstep(0, 0.04, f) * (1 - smoothstep(0.85, 1, f))
                p.h = SIMD4(Float(ang), Float(f), Float(bright), Float(rng.range(0, 50)))
                // most lift a big prominence; some are a bare, faster ejection with a small core
                let style: Float = rng.next() < 0.65 ? 0 : 1
                p.m = SIMD4(style, Float(rng.range(0.75, 1.25)), 0, 0)
            }
        }
        p.m.z = Float(exMoon.fraction)
        p.m.w = Float(bodyShare)
        return p
    }

    // MARK: Comet

    private static func comet(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                              _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let rate = c.cometEvents.rate
        var outburst = 0.0, shellRadius = 0.0, shellBright = 0.0
        if let (age, _) = events.active(EventSchedule.cometOutburst, rate: rate, at: t, demo: demo) {
            outburst = smoothstep(0, 3, age) * exp(-age / 30)
            // the ejected shell coasts outward, slowing as it spreads, and fades as it thins
            shellRadius = 0.32 * (1 - exp(-age / 25))
            shellBright = smoothstep(0, 2, age) * exp(-age / 22) * 1.2
                * (1 - smoothstep(EventSchedule.cometOutburst.duration - 15, EventSchedule.cometOutburst.duration, age))
        }
        var disconnectPos = -1.0, disconnectStrength = 0.0
        if let (age, _) = events.active(EventSchedule.tailDisconnect, rate: rate, at: t, demo: demo) {
            let f = age / EventSchedule.tailDisconnect.duration
            disconnectPos = 0.08 + 1.4 * f * c.cometTailLength
            disconnectStrength = smoothstep(0, 0.1, f) * (1 - smoothstep(0.75, 1, f))
        }
        // head lower right, tails streaming up and to the left, away from an off-screen sun;
        // in portrait the tails rise more steeply, up through the tall frame
        let s = cam.screenScale
        let head = cam.portrait ? SIMD2(0.3 * cam.aspect * s, cam.subjectY * s) : SIMD2(0.42 * cam.aspect, -0.32)
        let ion = simd_normalize(cam.portrait ? SIMD2(-0.4, 0.92) : SIMD2(-0.94, 0.36))
        p.a = SIMD4(Float(head.x), Float(head.y), Float(c.cometActivity), Float(c.cometTailLength))
        p.b = SIMD4(Float(ion.x), Float(ion.y), 0.35, Float(outburst))
        p.c = SIMD4(c.cometIonColor.light3(PickedColor.Level.cometIon), Float(disconnectPos))
        p.d = SIMD4(c.cometDustColor.light3(PickedColor.Level.cometDust), Float(disconnectStrength))
        p.e = SIMD4(Float(shellRadius), Float((t * 0.25).truncatingRemainder(dividingBy: 2 * .pi)), Float(shellBright), 0)
        return p
    }

    // MARK: Star close-up

    private static func stellarSurface(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                       _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        // Zoom 1 puts the limb across the lower middle; smaller zooms back off to the whole disk.
        // In portrait the disk stays centered with its top at the subject height.
        let radius = 1.7 * c.starZoom
        let s = cam.screenScale
        let center = cam.portrait ? SIMD2(0, cam.subjectY * s - radius)
            : SIMD2(c.starCenterX * cam.aspect, c.starLimbY - radius)
        let rotation = (t * 0.004 * c.starRotation).truncatingRemainder(dividingBy: 2 * .pi)
        let col = c.closeStar.color
        p.a = SIMD4(Float(center.x), Float(center.y), Float(radius), Float(rotation))
        p.b = SIMD4(col.r, col.g, col.b, Float(c.starSpots * c.closeStar.activity.clampedActivity))
        let arc = visibleLimb(center: center, radius: radius, halfWidth: cam.aspect * s, halfHeight: s)
        p.g = SIMD4(Float(arc.mid), Float(arc.half), 0, 0)
        func limbAngle(_ rng: inout Rng) -> Double { arc.mid + arc.half * rng.range(-0.85, 0.85) }
        // Eruptions and CMEs reach several radii out, so of a few candidate angles they take the
        // one with the most screen left beyond the limb (sideways, when the whole disk shows).
        let halfW = cam.aspect * s, halfH = s
        func roomyAngle(_ rng: inout Rng) -> Double {
            var best = limbAngle(&rng), bestRoom = -Double.infinity
            for i in 0..<4 {
                let a = i == 0 ? best : limbAngle(&rng)
                let dir = SIMD2(cos(a), sin(a)), pt = center + radius * dir
                let tx = dir.x == 0 ? .infinity : ((dir.x > 0 ? halfW : -halfW) - pt.x) / dir.x
                let ty = dir.y == 0 ? .infinity : ((dir.y > 0 ? halfH : -halfH) - pt.y) / dir.y
                let room = min(tx, ty)
                if room > bestRoom { (best, bestRoom) = (a, room) }
            }
            return best
        }

        // Slots: see the star close-up section of ShaderStars.swift. Progress is age / duration.
        let rate = c.starFlares.rate
        if case (let age, var rng)? = events.active(EventSchedule.stellarFlare, rate: rate, at: t, demo: demo) {
            let ang = limbAngle(&rng)
            let depth = rng.range(0.0, 0.015)   // just inside the limb, so its loop arcade stands clear of it
            let bright = smoothstep(0, 1.5, age) * exp(-age / 12)
            p.c = SIMD4(Float(ang), Float(depth), Float(bright * 3), Float(rng.range(0.05, 0.08)))
            p.f.x = Float(age / EventSchedule.stellarFlare.duration)
        }
        if case (let age, var rng)? = events.active(EventSchedule.surge, rate: rate, at: t, demo: demo) {
            let f = age / EventSchedule.surge.duration
            p.f.y = Float(limbAngle(&rng))
            p.f.z = Float(f)
            p.f.w = Float(smoothstep(0, 0.04, f) * (1 - smoothstep(0.85, 1, f)))
        }
        if case (let age, var rng)? = events.active(EventSchedule.coronalEjection, rate: rate, at: t, demo: demo) {
            let f = age / EventSchedule.coronalEjection.duration
            let ang = roomyAngle(&rng)
            p.d = SIMD4(Float(ang), Float(f), Float(smoothstep(0, 0.04, f) * (1 - smoothstep(0.7, 1, f))), Float(rng.range(0, 50)))
        }
        if case (let age, var rng)? = events.active(EventSchedule.prominenceEruption, rate: rate, at: t, demo: demo) {
            let f = age / EventSchedule.prominenceEruption.duration
            let ang = roomyAngle(&rng)
            p.e = SIMD4(Float(ang), Float(f), Float(smoothstep(0, 0.06, f) * (1 - smoothstep(0.85, 1, f))), Float(rng.range(0, 50)))
        }
        return p
    }

    // MARK: Quasar

    /// Optical depth of the quasar's dusty torus along the line from the nucleus at angle `i`
    /// from the jet axis; mirrors the smooth part of qsrTorus (the clumps average to about 1).
    static func quasarTorusDepth(_ i: Double) -> Double {
        let R = 0.55, a = 0.22, k = 5.0, n = 96, ds = 1.0 / Double(n)
        return (0..<n).reduce(0.0) { sum, step in
            let s = (Double(step) + 0.5) * ds * 1.5
            let rho = s * sin(i), h = s * cos(i)
            return sum + k * exp(-((rho - R) * (rho - R) + h * h) / (a * a)) * ds * 1.5
        }
    }

    private static func quasar(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                               _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        // the jet axis, from its angle to our line of sight and its direction on screen;
        // in portrait the jets run up the tall frame instead
        let i = c.quasarView / 180 * .pi
        let pa = (cam.portrait ? 90 - c.quasarJetAngle : c.quasarJetAngle) / 180 * .pi
        let axis = simd_normalize(sin(i) * (cos(pa) * cam.right + sin(pa) * cam.up) - cos(i) * cam.fwd)
        let e1 = simd_normalize(simd_cross(axis, cam.fwd))
        let L = 11.5 * c.quasarJetLength

        // Relativistic beaming: plasma at Lorentz factor 3 seen at angle i. The approaching jet's
        // light is Doppler boosted by delta^(2 + alpha), the receding one's dimmed. Knots also
        // appear to move faster on the approaching side (superluminal at moderate angles).
        let gamma = 3.0, beta = (1 - 1 / (gamma * gamma)).squareRoot()
        let mu = cos(i)
        let dA = 1 / (gamma * (1 - beta * mu)), dR = 1 / (gamma * (1 + beta * mu))
        let beamR = max(pow(dR / dA, 2.6), 0.02)
        let beamA = min(pow(dA / 0.55, 0.5), 2.0)       // held near 1 so a near-on view doesn't blow out
        let base = 0.075 * c.quasarKnotSpeed            // jet lengths per second along the axis
        let period = 1.4 * 4096
        let travelA = (t * base / (1 - beta * mu)).truncatingRemainder(dividingBy: period)
        let travelR = (t * base / (1 + beta * mu)).truncatingRemainder(dividingBy: period)

        // the flare: the core brightens sharply and launches a new knot up both jets
        var boost = 0.0, zfA = -1.0, zfR = -1.0, flareKnot = 0.0, hotBoost = 0.0
        if let (age, _) = events.active(EventSchedule.quasarFlare, rate: c.quasarEvents.rate, at: t, demo: demo) {
            let d = EventSchedule.quasarFlare.duration
            boost = 7 * smoothstep(0, 1.2, age) * exp(-age / 10) + 0.6 * exp(-age / 45)
            let f = max(age - 2, 0) / (d * 0.78)
            zfA = L * min(f, 1.05)
            zfR = zfA * (1 - beta * mu) / (1 + beta * mu)
            flareKnot = smoothstep(1, 5, age) * (1 - 0.45 * min(f, 1)) * (1 - smoothstep(0.92, 1.04, f))
            hotBoost = 2.5 * smoothstep(0.85, 1.0, f) * (1 - smoothstep(0, d * 0.2, age - d * 0.8))
        }

        typealias L_ = PickedColor.Level
        p.a = SIMD4(SIMD3<Float>(axis), Float(L))
        p.b = SIMD4(SIMD3<Float>(e1), Float(travelA))
        p.c = SIMD4(c.quasarJetColor.light3(L_.quasarJet), Float(travelR))
        p.d = SIMD4(c.quasarLobeColor.light3(L_.quasarLobe), Float(c.quasarJetBrightness))
        let spiral = 2 * Double.pi / (8 * 60) * 0.55     // arm pattern speed, corotating at mid-disk
        p.e = SIMD4(Float(beamA), Float(beamR), Float(c.quasarGalaxy), Float((t * spiral).truncatingRemainder(dividingBy: 2 * .pi)))
        p.f = SIMD4(Float(boost), Float(zfA), Float(flareKnot), Float(zfR))
        // the helix pattern drifts outward; the torus hides the core more as we see it edge-on
        let toUs = simd_normalize(cam.pos)
        let viewAngle = acos(min(max(simd_dot(toUs, axis), -1), 1))
        p.g = SIMD4(Float((t * 0.09).truncatingRemainder(dividingBy: 2 * .pi)), Float((t * 0.004).truncatingRemainder(dividingBy: 500)),
                    Float(hotBoost), Float(exp(-quasarTorusDepth(viewAngle))))
        return p
    }

    /// The stretch of limb that's on screen, as a middle angle and half span (radians), so limb
    /// features and events land where they can be seen at any zoom and framing.
    static func visibleLimb(center: SIMD2<Double>, radius: Double, halfWidth: Double, halfHeight: Double)
        -> (mid: Double, half: Double) {
        let n = 180
        let onScreen = (0..<n).map { i -> Bool in
            let a = Double(i) / Double(n) * 2 * .pi
            let pt = center + radius * SIMD2(cos(a), sin(a))
            return abs(pt.x) < halfWidth * 0.94 && abs(pt.y) < halfHeight * 0.94
        }
        if onScreen.allSatisfy({ $0 }) { return (.pi / 2, .pi) }
        // the longest run of on-screen angles, going around the circle
        var best = (start: 0, length: 0), start = 0, length = 0
        for i in 0..<(2 * n) {
            guard onScreen[i % n] else { length = 0; continue }
            if length == 0 { start = i }
            length += 1
            if length > best.length { best = (start, length) }
        }
        if best.length == 0 { return (atan2(-center.y, -center.x), 0.3) }   // the limb is off screen
        let step = 2 * Double.pi / Double(n)
        return (Double(best.start) * step + Double(best.length - 1) * step / 2, Double(best.length) * step / 2)
    }
}

private extension Double {
    /// Even "quiet" star types get a few spots in the close-up.
    var clampedActivity: Double { max(self, 0.35) }
}
