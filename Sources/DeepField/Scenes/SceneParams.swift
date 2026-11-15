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
