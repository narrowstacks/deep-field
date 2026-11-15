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
        case .gasGiant: return gasGiant(c, t, cam, events, demo)
        case .dysonSwarm: return dysonSwarm(c, t, cam, events, demo)
        case .comet: return comet(c, t, cam, events, demo)
        case .stellarSurface: return stellarSurface(c, t, cam, events, demo)
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
        // the ground drifts at a quarter of a real low orbit's pace by default
        p.f = SIMD4(Float(c.auroraClouds), Float(c.auroraMoonlight), Float(0.0012 * 0.25 * c.auroraDrift), Float(c.auroraLightning.rate))
        p.g = SIMD4(Float(c.auroraSunrise), 5.3, 0, 0)
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
