import Foundation
import simd

/// Rare sky events among the background stars. Time is split into fixed slots per event kind;
/// each slot rolls a seeded random number to decide whether an event happens in it, when, and
/// where. No state, so any moment can be evaluated directly (handy for snapshots).
struct EventSchedule {
    var seed: UInt64
    var enabled: Bool
    /// Where the current sky events appear. Finding a spot can take a dozen geodesic traces
    /// around a black hole, but it's fixed for an event's lifetime, so it's worked out once.
    private let placements = SkyPlacements()

    init(seed: UInt64, enabled: Bool = true) {
        self.seed = seed
        self.enabled = enabled
    }

    struct Kind {
        let id: UInt64
        let slot: Double       // seconds, at normal frequency
        let chance: Double
        let duration: Double
    }

    // Ids are stable: `--demo id:start` and the Customize window's "Show me" buttons use them.
    static let supernova = Kind(id: 1, slot: 360, chance: 0.75, duration: 150)
    static let comet     = Kind(id: 2, slot: 540, chance: 0.6, duration: 160)
    // wormhole scene
    static let farSupernova = Kind(id: 3, slot: 300, chance: 0.7, duration: 120)
    static let throatFlare  = Kind(id: 4, slot: 240, chance: 0.7, duration: 24)
    static let infall       = Kind(id: 5, slot: 420, chance: 0.6, duration: 45)
    static let emergence    = Kind(id: 6, slot: 480, chance: 0.6, duration: 45)
    // comet scene
    static let cometOutburst  = Kind(id: 7, slot: 360, chance: 0.6, duration: 90)
    static let tailDisconnect = Kind(id: 8, slot: 420, chance: 0.6, duration: 80)
    // star close-up scene
    static let stellarFlare    = Kind(id: 9, slot: 150, chance: 0.75, duration: 60)
    static let coronalEjection = Kind(id: 10, slot: 420, chance: 0.6, duration: 120)
    static let prominenceEruption = Kind(id: 11, slot: 600, chance: 0.6, duration: 150)
    static let surge           = Kind(id: 12, slot: 240, chance: 0.7, duration: 36)
    // planetary nebula scene
    static let shellEjection   = Kind(id: 13, slot: 480, chance: 0.65, duration: 150)
    // ringed planet scene
    static let whiteStorm      = Kind(id: 14, slot: 720, chance: 0.6, duration: 300)
    // aurora from orbit scene
    static let substorm        = Kind(id: 15, slot: 600, chance: 0.65, duration: 240)
    // gas giant storms scene (16 is the parked supernova remnant's flare)
    static let cometImpact     = Kind(id: 17, slot: 900, chance: 0.6, duration: 360)
    // protoplanetary disk scene
    static let accretionOutburst = Kind(id: 18, slot: 720, chance: 0.6, duration: 150)
    // neutron star merger scene: the merger closes every cycle on its own (SceneParams.mergerClock),
    // so this kind never fires from the schedule; it is here for --demo and Show me
    static let neutronMerger   = Kind(id: 19, slot: 600, chance: 0, duration: 80)
    // black hole merger scene: likewise ends every cycle (SceneParams.bbhClock)
    static let blackHoleMerger = Kind(id: 24, slot: 600, chance: 0, duration: 80)
    // dyson swarm scene
    static let swarmWave       = Kind(id: 21, slot: 720, chance: 0.6, duration: 45)
    // rogue planet scene
    static let starGlint       = Kind(id: 22, slot: 900, chance: 0.6, duration: 240)
    // eclipse scene: the window is long enough to wait for the next totality (see SceneParams.eclipse)
    static let eclipseEruption = Kind(id: 23, slot: 900, chance: 0.6, duration: 800)
    // quasar scene
    static let quasarFlare     = Kind(id: 20, slot: 900, chance: 0.6, duration: 130)

    /// If an event of this kind is running at time t: its age in seconds and a generator for its parameters.
    func active(_ k: Kind, rate: Double, at t: Double, demo: [UInt64: Double] = [:]) -> (age: Double, rng: Rng)? {
        if let s = demo[k.id], t >= s, t - s < k.duration {
            return (t - s, Rng(seed ^ UInt64(s * 1000) &* 0x9FB2_1C65_1E98_DF25))
        }
        guard rate > 0 else { return nil }
        let slotLength = max(k.slot / rate, k.duration * 1.15)
        let slot = floor(t / slotLength)
        var rng = Rng(seed ^ (k.id &* 0xA24B_AED4_963E_E407) ^ UInt64(bitPattern: Int64(slot)) &* 0x9FB2_1C65_1E98_DF25)
        guard rng.next() < k.chance else { return nil }
        let start = slot * slotLength + rng.next() * (slotLength - k.duration)
        let age = t - start
        guard age >= 0, age < k.duration else { return nil }
        return (age, rng)
    }

    /// The sky direction that actually appears at a screen position, after the scene bends the
    /// light. nil if that spot shows no sky of ours (inside the shadow or the wormhole throat,
    /// or behind the black hole's disk, which would hide the event's brightest moments).
    static func skyDirection(_ u: Double, _ v: Double, camera cam: Camera, config c: WallpaperConfig) -> SIMD3<Double>? {
        let d = cam.ray(u, v)
        switch c.scene {
        case .binary, .trinary, .galaxy, .pulsar, .nebula, .planetaryNebula, .ringedPlanet, .auroraOrbit, .gasGiant, .protoplanetaryDisk, .neutronMerger, .blackHoleMerger, .dysonSwarm, .roguePlanet, .eclipse, .comet, .stellarSurface, .quasar:
            return d
        case .wormhole:
            // lensing is mild away from the throat; just keep events clear of it
            let throatAngle = asin(min(1, c.throat * 1.8 / SceneGeometry.camDist))
            return acos(simd_dot(d, cam.center)) > throatAngle ? d : nil
        case .blackHole, .tidalDisruption:
            var pos = cam.pos
            var vel = d
            let h2 = simd_length_squared(simd_cross(pos, vel))
            func accel(_ p: SIMD3<Double>) -> SIMD3<Double> {
                let r2 = simd_length_squared(p)
                return -1.5 * h2 * p / (r2 * r2 * r2.squareRoot())
            }
            for _ in 0..<1500 {
                let r = simd_length(pos)
                if r < 1 { return nil }
                if r > simd_length(cam.pos) * 1.6 && simd_dot(pos, vel) > 0 { break }
                let dt = min(max(0.03 * r, 0.004), 1.0)
                let a0 = accel(pos)
                let np = pos + vel * dt + 0.5 * a0 * dt * dt
                vel += 0.5 * (a0 + accel(np)) * dt
                if c.scene == .blackHole && pos.y * np.y < 0 {
                    let hit = pos + (np - pos) * (pos.y / (pos.y - np.y))
                    let rh = simd_length(SIMD2(hit.x, hit.z))
                    if rh > Double(SceneGeometry.diskIn) * 0.85 && rh < c.diskSize * 0.8 { return nil }
                }
                pos = np
            }
            // A source almost straight behind the hole gets lensed into a full bright ring
            // around it: correct, but far from subtle, so events stay out of that cone.
            let out = simd_normalize(vel)
            return simd_dot(out, -simd_normalize(cam.pos)) > cos(0.3) ? nil : out
        }
    }

    private static func randomSky(_ rng: inout Rng, camera: Camera, config: WallpaperConfig,
                                  uRange: Double, vRange: Double) -> SIMD3<Double> {
        for _ in 0..<12 {
            if let d = skyDirection((rng.next() * 2 - 1) * uRange, (rng.next() * 2 - 1) * vRange,
                                    camera: camera, config: config) { return d }
        }
        return camera.ray(0.8, 0.6)
    }

    /// `count` random sky directions for the event whose generator is `rng`, advancing `rng`
    /// past them exactly as `randomSky` would. Cached per event instance and view.
    private func placed(_ k: Kind, count: Int, _ rng: inout Rng, camera: Camera, config: WallpaperConfig,
                        uRange: Double, vRange: Double) -> [SIMD3<Double>] {
        let key = SkyPlacements.Key(rng: rng.state, scene: config.scene, tilt: config.cameraTilt,
                                    throat: config.throat, diskSize: config.diskSize, aspect: camera.aspect)
        if let hit = placements.entries[k.id], hit.key == key {
            rng = hit.after
            return hit.dirs
        }
        let dirs = (0..<count).map { _ in
            Self.randomSky(&rng, camera: camera, config: config, uRange: uRange, vRange: vRange)
        }
        placements.entries[k.id] = (key, dirs, rng)
        return dirs
    }

    func gpu(at t: Double, config c: WallpaperConfig, camera cam: Camera, heightPixels: Int,
             demo: [UInt64: Double] = ConfigStore.shared.demoEvents) -> EventsGPU {
        var e = EventsGPU()
        guard enabled else { return e }
        let pa = 2 * cam.tanHalf / Double(heightPixels)   // radians per pixel

        if case (let age, var rng)? = active(Self.supernova, rate: c.supernovae.rate, at: t, demo: demo) {
            let d = placed(Self.supernova, count: 1, &rng, camera: cam, config: c, uRange: 0.85, vRange: 0.8)[0]
            let fadeOut = 1 - smoothstep(Self.supernova.duration - 30, Self.supernova.duration, age)
            let rise = smoothstep(0, 2.5, age)
            let core = 5.0 * rise * (0.15 + 0.85 * exp(-age / 18)) * fadeOut
            e.snDir = SIMD4(SIMD3<Float>(d), Float(core))
            e.snParams = SIMD4(Float(0.3 * rise * exp(-age / 10)),
                               Float(pa * (2 + age * 0.22)),
                               Float(0.35 * smoothstep(3, 10, age) * exp(-age / 45) * fadeOut),
                               Float(min(age / 70, 1)))
        }

        if case (let age, var rng)? = active(Self.comet, rate: c.comets.rate, at: t, demo: demo) {
            let ends = placed(Self.comet, count: 2, &rng, camera: cam, config: c, uRange: 0.95, vRange: 0.7)
            let a = ends[0], b = ends[1]
            let f = age / Self.comet.duration
            let head = simd_normalize(simd_mix(a, b, SIMD3(repeating: f)))
            // tail points away from the center of the scene (which sits along the view axis)
            var out = head - cam.center * simd_dot(head, cam.center)
            out = simd_length(out) > 1e-6 ? simd_normalize(out) : cam.up
            let tail = simd_normalize(head + out * (0.05 + 0.04 * rng.next()))
            let bright = pow(sin(.pi * f), 0.6) * 0.55
            e.cometHead = SIMD4(SIMD3<Float>(head), Float(bright))
            e.cometTail = SIMD4(SIMD3<Float>(tail), Float(pa * 1.1))
        }
        if c.scene == .wormhole { wormholeEvents(&e, t: t, config: c, camera: cam, demo: demo, heightPixels: heightPixels) }
        return e
    }

    private func wormholeEvents(_ e: inout EventsGPU, t: Double, config c: WallpaperConfig, camera cam: Camera,
                                demo: [UInt64: Double], heightPixels: Int) {
        let rate = c.wormholeEvents.rate
        let H = Double(heightPixels), W = H * cam.aspect
        guard let uv = cam.project(cam.center) else { return }
        let center = SIMD2((uv.x + 1) / 2 * W, (1 - uv.y) / 2 * H)
        let throatAngle = asin(min(1, c.throat / SceneGeometry.camDist))
        let radius = tan(throatAngle) / cam.tanHalf * H / 2
        e.throat = SIMD4(Float(center.x), Float(center.y), Float(radius), 0)

        // a supernova in the other universe, seen through the throat
        if case (let age, var rng)? = active(Self.farSupernova, rate: rate, at: t, demo: demo) {
            let e1 = simd_normalize(cam.pos)   // the far-side direction seen at the throat's center
            let jitter = SIMD3(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1)) * 0.6
            let d = simd_normalize(e1 + jitter)
            let rise = smoothstep(0, 2, age)
            let fade = 1 - smoothstep(Self.farSupernova.duration - 25, Self.farSupernova.duration, age)
            e.farSn = SIMD4(SIMD3<Float>(d), Float(4 * rise * (0.2 + 0.8 * exp(-age / 15)) * fade))
            e.farSnParams = SIMD4(Float(0.6 * rise * exp(-age / 12) * fade), Float(min(age / 60, 1)), 0, 0)
        }

        // a surge of light running along part of the rim
        if case (let age, var rng)? = active(Self.throatFlare, rate: rate, at: t, demo: demo) {
            let f = age / Self.throatFlare.duration
            let start = rng.range(0, 2 * .pi), sweep = rng.range(-1.5, 1.5)
            e.flare = SIMD4(Float(start + sweep * f), Float(pow(sin(.pi * f), 2) * 1.5), Float(0.35 + 0.5 * f), 0)
        }

        // something falls through, or comes out
        let size = max(2.0, H * 0.006)
        func place(_ dist: Double, _ ang: Double, _ vel: SIMD2<Double>, _ bright: Double) {
            let pos = center + SIMD2(cos(ang), sin(ang)) * dist
            // tangential smear where it skims the throat's edge (strong lensing)
            let stretch = 1 + 3 * exp(-pow((dist - radius) / (0.25 * radius), 2))
            let inside = dist < radius ? 0.55 : 1.0
            e.obj = SIMD4(Float(pos.x), Float(pos.y), Float(bright * inside), Float(size * (dist < radius ? max(dist / radius, 0.3) : 1)))
            let v = simd_length(vel) > 0 ? simd_normalize(vel) : SIMD2(1, 0)
            e.objDir = SIMD4(Float(v.x), Float(v.y), Float(stretch), 0)
        }
        if case (let age, var rng)? = active(Self.infall, rate: rate, at: t, demo: demo) {
            let f = age / Self.infall.duration
            let a0 = rng.range(0, 2 * .pi), spin = rng.range(0.4, 1.2) * (rng.next() < 0.5 ? -1 : 1)
            let d0 = radius * rng.range(3, 5)
            let dist = d0 * pow(1 - f, 1.3)            // accelerates as it falls
            let ang = a0 + spin * f
            let ahead = (d0 * pow(1 - min(f + 0.01, 1), 1.3)), angAhead = a0 + spin * min(f + 0.01, 1)
            let vel = SIMD2(cos(angAhead), sin(angAhead)) * ahead - SIMD2(cos(ang), sin(ang)) * dist
            place(dist, ang, vel, smoothstep(0, 0.1, f) * (1 - smoothstep(0.85, 1, f)))
        } else if case (let age, var rng)? = active(Self.emergence, rate: rate, at: t, demo: demo) {
            let f = age / Self.emergence.duration
            let a0 = rng.range(0, 2 * .pi), spin = rng.range(0.4, 1.2) * (rng.next() < 0.5 ? -1 : 1)
            let d1 = radius * rng.range(3, 5)
            let dist = d1 * pow(f, 1.3)
            let ang = a0 + spin * f
            let ahead = d1 * pow(min(f + 0.01, 1), 1.3), angAhead = a0 + spin * min(f + 0.01, 1)
            let vel = SIMD2(cos(angAhead), sin(angAhead)) * ahead - SIMD2(cos(ang), sin(ang)) * dist
            place(dist, ang, vel, smoothstep(0, 0.12, f) * (1 - smoothstep(0.8, 1, f)))
        }
    }
}

/// Per-view cache behind `EventSchedule.placed`: one entry per event kind, keyed by the event's
/// generator state (which identifies the instance) and everything the placement depends on.
private final class SkyPlacements {
    struct Key: Equatable {
        var rng: UInt64, scene: SceneKind, tilt: Double, throat: Double, diskSize: Double, aspect: Double
    }
    var entries: [UInt64: (key: Key, dirs: [SIMD3<Double>], after: Rng)] = [:]
}
