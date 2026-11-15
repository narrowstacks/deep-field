import Foundation
import simd

/// Per-scene uniforms for the newer scenes; each fragment shader reads these slots its own way.
struct SceneParamsGPU {
    var a = SIMD4<Float>(repeating: 0), b = SIMD4<Float>(repeating: 0)
    var c = SIMD4<Float>(repeating: 0), d = SIMD4<Float>(repeating: 0)
    var e = SIMD4<Float>(repeating: 0), f = SIMD4<Float>(repeating: 0)
    var g = SIMD4<Float>(repeating: 0), h = SIMD4<Float>(repeating: 0)
}

extension EventSchedule {
    static let cometOutburst   = Kind(id: 7, slot: 360, chance: 0.6, duration: 90)
    static let tailDisconnect  = Kind(id: 8, slot: 420, chance: 0.6, duration: 80)
    static let stellarFlare    = Kind(id: 9, slot: 150, chance: 0.75, duration: 40)
    static let coronalEjection = Kind(id: 10, slot: 420, chance: 0.6, duration: 120)
}

private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

private extension RGB {
    var v4: SIMD4<Float> { SIMD4(r, g, b, 0) }
}

enum SceneParams {
    static func build(_ c: WallpaperConfig, elapsed t: Double, camera cam: Camera,
                      width: Int, height: Int, events: EventSchedule,
                      demo: [UInt64: Double] = ConfigStore.shared.demoEvents) -> SceneParamsGPU {
        switch c.scene {
        case .tidalDisruption: return tidalDisruption(c, t, cam, width, height)
        case .pulsar: return pulsar(c, t, cam)
        case .nebula: return nebula(c)
        case .comet: return comet(c, t, cam, events, demo)
        case .stellarSurface: return stellarSurface(c, t, cam, events, demo)
        default: return SceneParamsGPU()
        }
    }

    // MARK: Star meets black hole

    /// Orbit of the doomed star in the disk plane (y = 0): r(nu) = rp (1 + e) / (1 + e cos nu).
    /// The star comes in from the far left, passes in front of the hole, and swings round behind it.
    static let tdePericenter = 4.0, tdeEccentricity = 0.97, tdeOrbitAngle = -1.18

    static func tdeOrbit(_ nu: Double) -> SIMD3<Double> {
        let r = tdePericenter * (1 + tdeEccentricity) / (1 + tdeEccentricity * cos(nu))
        let phi = nu + tdeOrbitAngle
        return SIMD3(r * cos(phi), 0, r * sin(phi))
    }

    /// Where on screen a point in the disk plane appears after lensing: Newton's method on the
    /// screen position, tracing each guess to its first crossing of the plane.
    static func lensedScreenPosition(of target: SIMD3<Double>, camera cam: Camera) -> SIMD2<Double>? {
        func planeHit(_ uv: SIMD2<Double>) -> SIMD2<Double>? {
            var pos = cam.pos, vel = cam.ray(uv.x, uv.y)
            let h2 = simd_length_squared(simd_cross(pos, vel))
            for _ in 0..<2000 {
                let r = simd_length(pos)
                if r < 1 { return nil }
                if r > simd_length(cam.pos) * 2.5 { return nil }
                let dt = min(max(0.03 * r, 0.004), 1.0)
                let r2 = r * r
                let a0 = -1.5 * h2 * pos / (r2 * r2 * r)
                let np = pos + vel * dt + 0.5 * a0 * dt * dt
                let nr = simd_length(np)
                let a1 = -1.5 * h2 * np / (nr * nr * nr * nr * nr)
                if pos.y * np.y < 0 {
                    let f = pos.y / (pos.y - np.y)
                    let hit = pos + (np - pos) * f
                    return SIMD2(hit.x, hit.z)
                }
                vel += 0.5 * (a0 + a1) * dt
                pos = np
            }
            return nil
        }
        guard var uv = cam.project(simd_normalize(target - cam.pos)) else { return nil }
        let goal = SIMD2(target.x, target.z)
        for _ in 0..<8 {
            guard let h = planeHit(uv) else { return nil }
            let err = goal - h
            if simd_length(err) < 0.01 { break }
            let du = 0.002
            guard let hx = planeHit(uv + SIMD2(du, 0)), let hy = planeHit(uv + SIMD2(0, du)) else { return nil }
            let j = simd_double2x2(columns: ((hx - h) / du, (hy - h) / du))
            guard abs(j.determinant) > 1e-9 else { return nil }
            var step = j.inverse * err
            if simd_length(step) > 0.2 { step = simd_normalize(step) * 0.2 }
            uv += step
        }
        return uv
    }

    private static func tidalDisruption(_ c: WallpaperConfig, _ t: Double, _ cam: Camera, _ W: Int, _ H: Int) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let cycle = c.tdeCycleMinutes * 60
        let s = t.truncatingRemainder(dividingBy: cycle) / cycle
        let approachEnd = 0.3, streamEnd = 0.9
        let tau = min(max((s - approachEnd) / (streamEnd - approachEnd), 0), 1)
        let fade = 1 - smoothstep(streamEnd, 1.0, s)
        // the stream brightens, then the newly formed disk flares and decays (roughly t^-5/3)
        let flare = s < approachEnd ? 0 : 0.4 + 2.2 * smoothstep(0.15, 0.35, tau) * pow(max(1 - (tau - 0.35) / 0.65, 0.05), 1.67)
        p.a = SIMD4(Float(tdeOrbitAngle), Float(tdePericenter), Float(tdeEccentricity), Float(tau))
        p.b = SIMD4(Float(s < approachEnd ? 0 : fade), Float(smoothstep(0.25, 0.75, tau) * fade),
                    Float(8 - 5 * smoothstep(0.3, 1, tau)), Float(flare * fade))
        let col = c.tdeStar.color
        p.e = SIMD4(col.r, col.g, col.b, 0)

        // the star itself, while it's still a star
        if s < approachEnd + 0.02 {
            let f = min(s / approachEnd, 1)
            let nu = -2.5 + 2.15 * pow(f, 1.6)
            let pos = tdeOrbit(nu)
            if let uv = lensedScreenPosition(of: pos, camera: cam) {
                let px = SIMD2((uv.x + 1) / 2 * Double(W), (1 - uv.y) / 2 * Double(H))
                let dist = simd_length(pos - cam.pos)
                let radius = max(2.0, 0.8 / dist / cam.tanHalf * Double(H) / 2)
                // tidal stretching along the orbit just before it comes apart
                let stretch = 1 + 2.5 * smoothstep(0.7, 1.0, f)
                var dir = SIMD2<Double>(1, 0)
                if let uv2 = lensedScreenPosition(of: tdeOrbit(nu + 0.05), camera: cam) {
                    let d = SIMD2((uv2.x - uv.x) * Double(W), -(uv2.y - uv.y) * Double(H))
                    if simd_length(d) > 1e-6 { dir = simd_normalize(d) }
                }
                let bright = smoothstep(0, 0.08, f) * (1 - smoothstep(0.95, 1.07, f)) * (1 + 0.6 * smoothstep(0.75, 1, f))
                p.c = SIMD4(Float(px.x), Float(px.y), Float(radius), Float(bright))
                p.d = SIMD4(Float(dir.x), Float(dir.y), Float(stretch), 0)
            }
        }
        return p
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
        let b1 = simd_normalize(simd_cross(spin, m) + SIMD3(1e-6, 0, 0))
        let width = c.pulsarBeamWidth / 180 * .pi
        // lighthouse flash when either beam sweeps across the camera
        let toCam = simd_normalize(cam.pos)
        let ang = acos(min(abs(simd_dot(m, toCam)), 1))
        let flash = exp(-pow(ang / (width * 1.3), 2))
        p.a = SIMD4(SIMD3<Float>(m), Float(width))
        p.b = SIMD4(SIMD3<Float>(spin), Float(flash))
        p.c = SIMD4(c.pulsarBeamColor.r, c.pulsarBeamColor.g, c.pulsarBeamColor.b, c.pulsarNebula ? 1 : 0)
        p.d = SIMD4(c.pulsarNebulaColor.r, c.pulsarNebulaColor.g, c.pulsarNebulaColor.b, c.pulsarFieldLines ? 1 : 0)
        p.e = SIMD4(SIMD3<Float>(b1), 0)
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
        var outburst = 0.0
        if let (age, _) = events.active(EventSchedule.cometOutburst, rate: rate, at: t, demo: demo) {
            outburst = smoothstep(0, 3, age) * exp(-age / 30)
        }
        var disconnectPos = -1.0, disconnectStrength = 0.0
        if let (age, _) = events.active(EventSchedule.tailDisconnect, rate: rate, at: t, demo: demo) {
            let f = age / EventSchedule.tailDisconnect.duration
            disconnectPos = 0.08 + 1.4 * f * c.cometTailLength
            disconnectStrength = smoothstep(0, 0.1, f) * (1 - smoothstep(0.75, 1, f))
        }
        // head lower right, tails streaming up and to the left, away from an off-screen sun
        let head = SIMD2(0.42 * cam.aspect, -0.32)
        let ion = simd_normalize(SIMD2(-0.94, 0.36))
        p.a = SIMD4(Float(head.x), Float(head.y), Float(c.cometActivity), Float(c.cometTailLength))
        p.b = SIMD4(Float(ion.x), Float(ion.y), 0.35, Float(outburst))
        p.c = SIMD4(c.cometIonColor.r, c.cometIonColor.g, c.cometIonColor.b, Float(disconnectPos))
        p.d = SIMD4(c.cometDustColor.r, c.cometDustColor.g, c.cometDustColor.b, Float(disconnectStrength))
        p.e = SIMD4(Float(cam.aspect), Float((t * 0.25).truncatingRemainder(dividingBy: 2 * .pi)), 0, 0)
        return p
    }

    // MARK: Star close-up

    private static func stellarSurface(_ c: WallpaperConfig, _ t: Double, _ cam: Camera,
                                       _ events: EventSchedule, _ demo: [UInt64: Double]) -> SceneParamsGPU {
        var p = SceneParamsGPU()
        let radius = 1.7
        let center = SIMD2(-0.15 * cam.aspect, 0.12 - radius)   // the limb arcs across the lower middle
        let rotation = (t * 0.004 * c.starRotation).truncatingRemainder(dividingBy: 2 * .pi)
        let col = c.closeStar.color
        p.a = SIMD4(Float(center.x), Float(center.y), Float(radius), Float(rotation))
        p.b = SIMD4(col.r, col.g, col.b, Float(c.starSpots * c.closeStar.activity.clampedActivity))
        p.e = SIMD4(Float(cam.aspect), 0, 0, 0)

        let rate = c.starFlares.rate
        if var (age, rng) = events.active(EventSchedule.stellarFlare, rate: rate, at: t, demo: demo) {
            let ang = rng.range(0.6, 2.5)
            let depth = rng.range(0.03, 0.14)
            let pos = center + SIMD2(cos(ang), sin(ang)) * radius * (1 - depth)
            let bright = smoothstep(0, 1.5, age) * exp(-age / 9)
            p.c = SIMD4(Float(pos.x), Float(pos.y), Float(bright * 3), Float(rng.range(0.03, 0.06)))
            p.f = SIMD4(Float(ang), Float(bright), 0, 0)
        }
        if var (age, rng) = events.active(EventSchedule.coronalEjection, rate: rate, at: t, demo: demo) {
            let f = age / EventSchedule.coronalEjection.duration
            let ang = rng.range(0.7, 2.4)
            p.d = SIMD4(Float(ang), Float(0.03 + 1.2 * pow(f, 0.8)), Float(smoothstep(0, 0.05, f) * (1 - smoothstep(0.6, 1, f))), Float(0.04 + 0.12 * f))
        }
        return p
    }
}

private extension Double {
    /// Even "quiet" star types get a few spots in the close-up.
    var clampedActivity: Double { max(self, 0.35) }
}
