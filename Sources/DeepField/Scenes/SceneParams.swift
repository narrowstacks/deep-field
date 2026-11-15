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
        func scaled(_ col: RGB, _ k: Double, _ on: Bool = true) -> SIMD3<Float> {
            on ? SIMD3(col.r, col.g, col.b) * Float(max(k, 0)) : .zero
        }
        p.a = SIMD4(SIMD3<Float>(m), Float(width))
        p.b = SIMD4(SIMD3<Float>(spin), Float(flash))
        p.c = SIMD4(scaled(c.pulsarBeamColor, c.pulsarBeamIntensity), Float(beams))
        p.d = SIMD4(scaled(c.pulsarNebulaColor, c.pulsarNebulaIntensity, c.pulsarNebula),
                    !c.pulsarFieldLines ? 0 : c.pulsarFieldStyle == .lines ? 1 : 2)
        p.e = SIMD4(scaled(c.pulsarFieldColor, c.pulsarFieldIntensity), Float(trail))
        p.f = SIMD4(scaled(c.pulsarRingColor, c.pulsarRingIntensity, c.pulsarRing), 0)
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
        p.c = SIMD4(c.cometIonColor.r, c.cometIonColor.g, c.cometIonColor.b, Float(disconnectPos))
        p.d = SIMD4(c.cometDustColor.r, c.cometDustColor.g, c.cometDustColor.b, Float(disconnectStrength))
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
            let ang = limbAngle(&rng)
            p.d = SIMD4(Float(ang), Float(f), Float(smoothstep(0, 0.04, f) * (1 - smoothstep(0.7, 1, f))), Float(rng.range(0, 50)))
        }
        if case (let age, var rng)? = events.active(EventSchedule.prominenceEruption, rate: rate, at: t, demo: demo) {
            let f = age / EventSchedule.prominenceEruption.duration
            let ang = limbAngle(&rng)
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
