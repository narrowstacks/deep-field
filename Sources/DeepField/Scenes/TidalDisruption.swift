import Foundation
import simd

// Star meets black hole (tidal disruption): the star's orbit, where it shows up on screen after
// lensing, and the stream and disk state the lensed fragment shader draws.

extension SceneParams {
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

    static func tidalDisruption(_ c: WallpaperConfig, _ t: Double, _ cam: Camera, _ W: Int, _ H: Int) -> SceneParamsGPU {
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
}
