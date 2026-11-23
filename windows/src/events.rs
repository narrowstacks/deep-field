//! Rare sky events among the background stars, and each scene's own events (Scenes/Events.swift).
//! Time is split into fixed slots per event kind; each slot rolls a seeded random number to
//! decide whether an event happens in it, when, and where. No state, so any moment can be
//! evaluated directly (snapshots use seed 1).
#![allow(dead_code)]

use std::collections::HashMap;
use std::f64::consts::PI;
use std::sync::Mutex;

use glam::{DVec2, DVec3};

use crate::camera::{Camera, SceneGeometry};
use crate::config::{SceneKind, WallpaperConfig};
use crate::gpu_types::EventsGpu;
use crate::math::{mix, normalize, smoothstep, v4w, Rng};

/// Demo starts: event kind id -> start time in seconds (`--demo id:start`, "Show me").
pub type DemoMap = HashMap<u64, f64>;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Kind {
    pub id: u64,
    /// seconds, at normal frequency
    pub slot: f64,
    pub chance: f64,
    pub duration: f64,
}

const fn kind(id: u64, slot: f64, chance: f64, duration: f64) -> Kind {
    Kind { id, slot, chance, duration }
}

// Ids are stable: `--demo id:start` and the Customize window's "Show me" buttons use them.
pub const SUPERNOVA: Kind = kind(1, 360.0, 0.75, 150.0);
pub const COMET: Kind = kind(2, 540.0, 0.6, 160.0);
// wormhole scene
pub const FAR_SUPERNOVA: Kind = kind(3, 300.0, 0.7, 120.0);
pub const THROAT_FLARE: Kind = kind(4, 240.0, 0.7, 24.0);
pub const INFALL: Kind = kind(5, 420.0, 0.6, 45.0);
pub const EMERGENCE: Kind = kind(6, 480.0, 0.6, 45.0);
// comet scene
pub const COMET_OUTBURST: Kind = kind(7, 360.0, 0.6, 90.0);
pub const TAIL_DISCONNECT: Kind = kind(8, 420.0, 0.6, 80.0);
// star close-up scene
pub const STELLAR_FLARE: Kind = kind(9, 150.0, 0.75, 60.0);
pub const CORONAL_EJECTION: Kind = kind(10, 420.0, 0.6, 120.0);
pub const PROMINENCE_ERUPTION: Kind = kind(11, 600.0, 0.6, 150.0);
pub const SURGE: Kind = kind(12, 240.0, 0.7, 36.0);
// planetary nebula scene
pub const SHELL_EJECTION: Kind = kind(13, 480.0, 0.65, 150.0);
// ringed planet scene
pub const WHITE_STORM: Kind = kind(14, 720.0, 0.6, 300.0);
// aurora from orbit scene
pub const SUBSTORM: Kind = kind(15, 600.0, 0.65, 240.0);
// gas giant storms scene (16 is the parked supernova remnant's flare)
pub const COMET_IMPACT: Kind = kind(17, 900.0, 0.6, 360.0);
// protoplanetary disk scene
pub const ACCRETION_OUTBURST: Kind = kind(18, 720.0, 0.6, 150.0);
// The mergers close every cycle on their own (scene_params' clocks), so these never fire from
// the schedule; they are here for --demo.
pub const NEUTRON_MERGER: Kind = kind(19, 600.0, 0.0, 80.0);
pub const BLACK_HOLE_MERGER: Kind = kind(24, 600.0, 0.0, 80.0);
// dyson swarm scene
pub const SWARM_WAVE: Kind = kind(21, 720.0, 0.6, 45.0);
// rogue planet scene
pub const STAR_GLINT: Kind = kind(22, 900.0, 0.6, 240.0);
// eclipse scene: the window is long enough to wait for the next totality
pub const ECLIPSE_ERUPTION: Kind = kind(23, 900.0, 0.6, 800.0);
// quasar scene
pub const QUASAR_FLARE: Kind = kind(20, 900.0, 0.6, 130.0);

/// Every event kind by name, with the scene it belongs to (None for the shared sky events).
pub const NAMED: [(&str, Kind, Option<SceneKind>); 23] = [
    ("supernova", SUPERNOVA, None), ("comet", COMET, None),
    ("farSupernova", FAR_SUPERNOVA, Some(SceneKind::Wormhole)), ("throatFlare", THROAT_FLARE, Some(SceneKind::Wormhole)),
    ("infall", INFALL, Some(SceneKind::Wormhole)), ("emergence", EMERGENCE, Some(SceneKind::Wormhole)),
    ("cometOutburst", COMET_OUTBURST, Some(SceneKind::Comet)), ("tailDisconnect", TAIL_DISCONNECT, Some(SceneKind::Comet)),
    ("stellarFlare", STELLAR_FLARE, Some(SceneKind::StellarSurface)),
    ("coronalEjection", CORONAL_EJECTION, Some(SceneKind::StellarSurface)),
    ("prominenceEruption", PROMINENCE_ERUPTION, Some(SceneKind::StellarSurface)),
    ("surge", SURGE, Some(SceneKind::StellarSurface)),
    ("shellEjection", SHELL_EJECTION, Some(SceneKind::PlanetaryNebula)),
    ("whiteStorm", WHITE_STORM, Some(SceneKind::RingedPlanet)),
    ("substorm", SUBSTORM, Some(SceneKind::AuroraOrbit)), ("cometImpact", COMET_IMPACT, Some(SceneKind::GasGiant)),
    ("accretionOutburst", ACCRETION_OUTBURST, Some(SceneKind::ProtoplanetaryDisk)),
    ("neutronMerger", NEUTRON_MERGER, Some(SceneKind::NeutronMerger)),
    ("blackHoleMerger", BLACK_HOLE_MERGER, Some(SceneKind::BlackHoleMerger)),
    ("swarmWave", SWARM_WAVE, Some(SceneKind::DysonSwarm)),
    ("starGlint", STAR_GLINT, Some(SceneKind::RoguePlanet)),
    ("eclipseEruption", ECLIPSE_ERUPTION, Some(SceneKind::Eclipse)),
    ("quasarFlare", QUASAR_FLARE, Some(SceneKind::Quasar)),
];

/// Per-view cache behind `placed`: one entry per event kind, keyed by the event's generator
/// state (which identifies the instance) and everything the placement depends on.
#[derive(Clone, Copy, PartialEq)]
struct PlacementKey {
    rng: u64,
    scene: SceneKind,
    tilt: f64,
    throat: f64,
    disk_size: f64,
    aspect: f64,
}

struct Placement {
    key: PlacementKey,
    dirs: Vec<DVec3>,
    after: Rng,
}

pub struct EventSchedule {
    pub seed: u64,
    /// Off stops the shared sky events only (`--no-events`); scene events still fire.
    pub enabled: bool,
    /// Demo starts `gpu` uses (Swift reads ConfigStore.shared.demoEvents); `gpu_with_demo` takes
    /// them explicitly instead.
    pub demo: DemoMap,
    /// Where the current sky events appear. Finding a spot can take a dozen geodesic traces
    /// around a black hole, but it's fixed for an event's lifetime, so it's worked out once.
    placements: Mutex<HashMap<u64, Placement>>,
}

impl Clone for EventSchedule {
    fn clone(&self) -> Self {
        let mut e = EventSchedule::with_enabled(self.seed, self.enabled);
        e.demo = self.demo.clone();
        e
    }
}

impl std::fmt::Debug for EventSchedule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EventSchedule").field("seed", &self.seed).field("enabled", &self.enabled).finish()
    }
}

impl EventSchedule {
    pub fn new(seed: u64) -> Self {
        Self::with_enabled(seed, true)
    }

    pub fn with_enabled(seed: u64, enabled: bool) -> Self {
        EventSchedule { seed, enabled, demo: DemoMap::new(), placements: Mutex::new(HashMap::new()) }
    }

    /// If an event of this kind is running at time t: its age in seconds and a generator for its
    /// parameters. A demo start overrides the schedule for that kind.
    pub fn active(&self, k: Kind, rate: f64, t: f64, demo: &DemoMap) -> Option<(f64, Rng)> {
        if let Some(&s) = demo.get(&k.id) {
            if t >= s && t - s < k.duration {
                // Swift's UInt64(s * 1000) truncates toward zero; `&*` binds tighter than `^`
                return Some((t - s, Rng::new(self.seed ^ ((s * 1000.0) as u64).wrapping_mul(0x9FB2_1C65_1E98_DF25))));
            }
        }
        if !(rate > 0.0) {
            return None;
        }
        let slot_length = (k.slot / rate).max(k.duration * 1.15);
        let slot = (t / slot_length).floor();
        let mut rng = Rng::new(
            self.seed
                ^ k.id.wrapping_mul(0xA24B_AED4_963E_E407)
                ^ ((slot as i64) as u64).wrapping_mul(0x9FB2_1C65_1E98_DF25),
        );
        if !(rng.next() < k.chance) {
            return None;
        }
        let start = slot * slot_length + rng.next() * (slot_length - k.duration);
        let age = t - start;
        if !(age >= 0.0 && age < k.duration) {
            return None;
        }
        Some((age, rng))
    }

    /// The sky direction that actually appears at a screen position, after the scene bends the
    /// light. None if that spot shows no sky of ours (inside the shadow or the wormhole throat,
    /// or behind the black hole's disk, which would hide the event's brightest moments).
    pub fn sky_direction(u: f64, v: f64, cam: &Camera, c: &WallpaperConfig) -> Option<DVec3> {
        let d = cam.ray(u, v);
        match c.scene {
            SceneKind::Wormhole => {
                // lensing is mild away from the throat; just keep events clear of it
                let throat_angle = (c.throat * 1.8 / SceneGeometry::CAM_DIST).min(1.0).asin();
                if d.dot(cam.center()).acos() > throat_angle { Some(d) } else { None }
            }
            SceneKind::BlackHole | SceneKind::TidalDisruption => {
                // Trace the photon through the Schwarzschild geometry: in these units the orbit
                // equation gives an extra inward pull of 1.5 h^2 / r^5 times the position.
                let mut pos = cam.pos;
                let mut vel = d;
                let h2 = pos.cross(vel).length_squared();
                let accel = |p: DVec3| -> DVec3 {
                    let r2 = p.length_squared();
                    (-1.5 * h2) * p / (r2 * r2 * r2.sqrt())
                };
                let cam_r = cam.pos.length();
                for _ in 0..1500 {
                    let r = pos.length();
                    if r < 1.0 {
                        return None;
                    }
                    if r > cam_r * 1.6 && pos.dot(vel) > 0.0 {
                        break;
                    }
                    let dt = (0.03 * r).max(0.004).min(1.0);
                    let a0 = accel(pos);
                    let np = pos + vel * dt + 0.5 * a0 * dt * dt;
                    vel += 0.5 * (a0 + accel(np)) * dt;
                    if c.scene == SceneKind::BlackHole && pos.y * np.y < 0.0 {
                        let hit = pos + (np - pos) * (pos.y / (pos.y - np.y));
                        let rh = DVec2::new(hit.x, hit.z).length();
                        if rh > SceneGeometry::DISK_IN as f64 * 0.85 && rh < c.disk_size * 0.8 {
                            return None;
                        }
                    }
                    pos = np;
                }
                // A source almost straight behind the hole gets lensed into a full bright ring
                // around it: correct, but far from subtle, so events stay out of that cone.
                let out = normalize(vel);
                if out.dot(-normalize(cam.pos)) > 0.3f64.cos() { None } else { Some(out) }
            }
            _ => Some(d),
        }
    }

    fn random_sky(rng: &mut Rng, cam: &Camera, c: &WallpaperConfig, u_range: f64, v_range: f64) -> DVec3 {
        for _ in 0..12 {
            let u = (rng.next() * 2.0 - 1.0) * u_range;
            let v = (rng.next() * 2.0 - 1.0) * v_range;
            if let Some(d) = Self::sky_direction(u, v, cam, c) {
                return d;
            }
        }
        cam.ray(0.8, 0.6)
    }

    /// `count` random sky directions for the event whose generator is `rng`, advancing `rng`
    /// past them exactly as `random_sky` would. Cached per event instance and view.
    fn placed(&self, k: Kind, count: usize, rng: &mut Rng, cam: &Camera, c: &WallpaperConfig,
              u_range: f64, v_range: f64) -> Vec<DVec3> {
        let key = PlacementKey {
            rng: rng.state, scene: c.scene, tilt: c.camera_tilt(), throat: c.throat,
            disk_size: c.disk_size, aspect: cam.aspect,
        };
        let mut cache = self.placements.lock().unwrap();
        if let Some(hit) = cache.get(&k.id) {
            if hit.key == key {
                *rng = hit.after;
                return hit.dirs.clone();
            }
        }
        let dirs: Vec<DVec3> = (0..count).map(|_| Self::random_sky(rng, cam, c, u_range, v_range)).collect();
        cache.insert(k.id, Placement { key, dirs: dirs.clone(), after: *rng });
        dirs
    }

    /// The shared sky events (and the wormhole's own) for the frame at `t`, with `self.demo`.
    pub fn gpu(&self, t: f64, c: &WallpaperConfig, cam: &Camera, height_pixels: u32) -> EventsGpu {
        self.gpu_with_demo(t, c, cam, height_pixels, &self.demo)
    }

    pub fn gpu_with_demo(&self, t: f64, c: &WallpaperConfig, cam: &Camera, height_pixels: u32, demo: &DemoMap) -> EventsGpu {
        let mut e = EventsGpu::default();
        if !self.enabled {
            return e;
        }
        // radians per pixel
        let pa = 2.0 * cam.tan_half / height_pixels as f64;

        if let Some((age, mut rng)) = self.active(SUPERNOVA, c.supernovae.rate(), t, demo) {
            let d = self.placed(SUPERNOVA, 1, &mut rng, cam, c, 0.85, 0.8)[0];
            let fade_out = 1.0 - smoothstep(SUPERNOVA.duration - 30.0, SUPERNOVA.duration, age);
            let rise = smoothstep(0.0, 2.5, age);
            let core = 5.0 * rise * (0.15 + 0.85 * (-age / 18.0).exp()) * fade_out;
            e.sn_dir = v4w(d, core as f32);
            e.sn_params = [
                (0.3 * rise * (-age / 10.0).exp()) as f32,
                (pa * (2.0 + age * 0.22)) as f32,
                (0.35 * smoothstep(3.0, 10.0, age) * (-age / 45.0).exp() * fade_out) as f32,
                (age / 70.0).min(1.0) as f32,
            ];
        }

        if let Some((age, mut rng)) = self.active(COMET, c.comets.rate(), t, demo) {
            let ends = self.placed(COMET, 2, &mut rng, cam, c, 0.95, 0.7);
            let (a, b) = (ends[0], ends[1]);
            let f = age / COMET.duration;
            let head = normalize(mix(a, b, f));
            // the tail points away from the center of the scene (which sits along the view axis)
            let center = cam.center();
            let mut out = head - center * head.dot(center);
            out = if out.length() > 1e-6 { normalize(out) } else { cam.up };
            let tail = normalize(head + out * (0.05 + 0.04 * rng.next()));
            let bright = (PI * f).sin().powf(0.6) * 0.55;
            e.comet_head = v4w(head, bright as f32);
            e.comet_tail = v4w(tail, (pa * 1.1) as f32);
        }
        if c.scene == SceneKind::Wormhole {
            self.wormhole_events(&mut e, t, c, cam, demo, height_pixels);
        }
        e
    }

    fn wormhole_events(&self, e: &mut EventsGpu, t: f64, c: &WallpaperConfig, cam: &Camera, demo: &DemoMap,
                       height_pixels: u32) {
        let rate = c.wormhole_events.rate();
        let h = height_pixels as f64;
        let w = h * cam.aspect;
        let Some(uv) = cam.project(cam.center()) else { return };
        let center = DVec2::new((uv.x + 1.0) / 2.0 * w, (1.0 - uv.y) / 2.0 * h);
        let throat_angle = (c.throat / SceneGeometry::CAM_DIST).min(1.0).asin();
        let radius = throat_angle.tan() / cam.tan_half * h / 2.0;
        e.throat = [center.x as f32, center.y as f32, radius as f32, 0.0];

        // a supernova in the other universe, seen through the throat
        if let Some((age, mut rng)) = self.active(FAR_SUPERNOVA, rate, t, demo) {
            // the far-side direction seen at the throat's center
            let e1 = normalize(cam.pos);
            let jx = rng.range(-1.0, 1.0);
            let jy = rng.range(-1.0, 1.0);
            let jz = rng.range(-1.0, 1.0);
            let jitter = DVec3::new(jx, jy, jz) * 0.6;
            let d = normalize(e1 + jitter);
            let rise = smoothstep(0.0, 2.0, age);
            let fade = 1.0 - smoothstep(FAR_SUPERNOVA.duration - 25.0, FAR_SUPERNOVA.duration, age);
            e.far_sn = v4w(d, (4.0 * rise * (0.2 + 0.8 * (-age / 15.0).exp()) * fade) as f32);
            e.far_sn_params = [(0.6 * rise * (-age / 12.0).exp() * fade) as f32, (age / 60.0).min(1.0) as f32, 0.0, 0.0];
        }

        // a surge of light running along part of the rim
        if let Some((age, mut rng)) = self.active(THROAT_FLARE, rate, t, demo) {
            let f = age / THROAT_FLARE.duration;
            let start = rng.range(0.0, 2.0 * PI);
            let sweep = rng.range(-1.5, 1.5);
            e.flare = [(start + sweep * f) as f32, ((PI * f).sin().powf(2.0) * 1.5) as f32, (0.35 + 0.5 * f) as f32, 0.0];
        }

        // something falls through, or comes out
        let size = 2.0f64.max(h * 0.006);
        let mut place = |dist: f64, ang: f64, vel: DVec2, bright: f64| {
            let pos = center + DVec2::new(ang.cos(), ang.sin()) * dist;
            // tangential smear where it skims the throat's edge (strong lensing)
            let stretch = 1.0 + 3.0 * (-((dist - radius) / (0.25 * radius)).powf(2.0)).exp();
            let inside = if dist < radius { 0.55 } else { 1.0 };
            let s = size * if dist < radius { (dist / radius).max(0.3) } else { 1.0 };
            e.obj = [pos.x as f32, pos.y as f32, (bright * inside) as f32, s as f32];
            let v = if vel.length() > 0.0 { vel * (1.0 / vel.length_squared().sqrt()) } else { DVec2::new(1.0, 0.0) };
            e.obj_dir = [v.x as f32, v.y as f32, stretch as f32, 0.0];
        };
        let spin_of = |rng: &mut Rng| -> f64 {
            let s = rng.range(0.4, 1.2);
            s * if rng.next() < 0.5 { -1.0 } else { 1.0 }
        };
        if let Some((age, mut rng)) = self.active(INFALL, rate, t, demo) {
            let f = age / INFALL.duration;
            let a0 = rng.range(0.0, 2.0 * PI);
            let spin = spin_of(&mut rng);
            let d0 = radius * rng.range(3.0, 5.0);
            // accelerates as it falls
            let dist = d0 * (1.0 - f).powf(1.3);
            let ang = a0 + spin * f;
            let ahead = d0 * (1.0 - (f + 0.01).min(1.0)).powf(1.3);
            let ang_ahead = a0 + spin * (f + 0.01).min(1.0);
            let vel = DVec2::new(ang_ahead.cos(), ang_ahead.sin()) * ahead - DVec2::new(ang.cos(), ang.sin()) * dist;
            place(dist, ang, vel, smoothstep(0.0, 0.1, f) * (1.0 - smoothstep(0.85, 1.0, f)));
        } else if let Some((age, mut rng)) = self.active(EMERGENCE, rate, t, demo) {
            let f = age / EMERGENCE.duration;
            let a0 = rng.range(0.0, 2.0 * PI);
            let spin = spin_of(&mut rng);
            let d1 = radius * rng.range(3.0, 5.0);
            let dist = d1 * f.powf(1.3);
            let ang = a0 + spin * f;
            let ahead = d1 * (f + 0.01).min(1.0).powf(1.3);
            let ang_ahead = a0 + spin * (f + 0.01).min(1.0);
            let vel = DVec2::new(ang_ahead.cos(), ang_ahead.sin()) * ahead - DVec2::new(ang.cos(), ang.sin()) * dist;
            place(dist, ang, vel, smoothstep(0.0, 0.12, f) * (1.0 - smoothstep(0.8, 1.0, f)));
        }
    }

    /// When each event kind (the sky's and each scene's own) starts in the first `minutes`, at
    /// the configured frequencies, as (id, name, start seconds), like `--list-events`. The id is
    /// what `--demo` takes.
    pub fn list(&self, minutes: f64, c: &WallpaperConfig) -> Vec<(u64, &'static str, Vec<i64>)> {
        let w = c.wormhole_events.rate();
        let cm = c.comet_events.rate();
        let st = c.star_flares.rate();
        let kinds: [(&str, Kind, f64); 21] = [
            ("supernova", SUPERNOVA, c.supernovae.rate()), ("comet", COMET, c.comets.rate()),
            ("farSupernova", FAR_SUPERNOVA, w), ("throatFlare", THROAT_FLARE, w),
            ("infall", INFALL, w), ("emergence", EMERGENCE, w),
            ("cometOutburst", COMET_OUTBURST, cm), ("tailDisconnect", TAIL_DISCONNECT, cm),
            ("stellarFlare", STELLAR_FLARE, st), ("coronalEjection", CORONAL_EJECTION, st),
            ("prominenceEruption", PROMINENCE_ERUPTION, st), ("surge", SURGE, st),
            ("shellEjection", SHELL_EJECTION, c.planetary_events.rate()),
            ("whiteStorm", WHITE_STORM, c.ringed_events.rate()),
            ("substorm", SUBSTORM, c.aurora_events.rate()),
            ("cometImpact", COMET_IMPACT, c.gas_events.rate()),
            ("accretionOutburst", ACCRETION_OUTBURST, c.proto_events.rate()),
            ("swarmWave", SWARM_WAVE, c.dyson_events.rate()),
            ("starGlint", STAR_GLINT, c.rogue_events.rate()),
            ("eclipseEruption", ECLIPSE_ERUPTION, c.eclipse_events.rate()),
            ("quasarFlare", QUASAR_FLARE, c.quasar_events.rate()),
        ];
        let none = DemoMap::new();
        let mut out = Vec::new();
        for (name, k, rate) in kinds {
            let mut starts = Vec::new();
            let mut t = 0.0;
            while t < minutes * 60.0 {
                if let Some((age, _)) = self.active(k, rate, t, &none) {
                    if age < 1.0 {
                        starts.push(t as i64);
                    }
                }
                t += 1.0;
            }
            out.push((k.id, name, starts));
        }
        // the mergers start each of their scene's cycles rather than being scheduled
        let mut mergers = Vec::new();
        let mut bbh = Vec::new();
        let mut t = 0.0;
        while t < minutes * 60.0 {
            if crate::scene_params::merger_clock(c, t, &none).u < 1.0 {
                mergers.push(t as i64);
            }
            if crate::scene_params::bbh_clock(c, t, &none).u < 1.0 {
                bbh.push(t as i64);
            }
            t += 1.0;
        }
        out.push((NEUTRON_MERGER.id, "neutronMerger", mergers));
        out.push((BLACK_HOLE_MERGER.id, "blackHoleMerger", bbh));
        out
    }
}

/// Parses `--demo id:start,...` into a demo map; malformed pairs are skipped, as in Swift.
pub fn parse_demo(spec: &str) -> DemoMap {
    let mut m = DemoMap::new();
    for pair in spec.split(',').filter(|s| !s.is_empty()) {
        let parts: Vec<&str> = pair.split(':').filter(|s| !s.is_empty()).collect();
        if parts.len() == 2 {
            if let (Ok(id), Ok(start)) = (parts[0].parse::<u64>(), parts[1].parse::<f64>()) {
                m.insert(id, start);
            }
        }
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_is_deterministic() {
        let c = WallpaperConfig::default();
        let a = EventSchedule::new(1).list(60.0, &c);
        let b = EventSchedule::new(1).list(60.0, &c);
        assert_eq!(a, b);
        let other = EventSchedule::new(2).list(60.0, &c);
        assert_ne!(a, other);
        // every start found by the listing is an active event of age under a second
        let s = EventSchedule::new(1);
        for (id, _, starts) in &a {
            let Some(k) = NAMED.iter().find(|n| n.1.id == *id).map(|n| n.1) else { continue };
            if k.chance == 0.0 {
                continue;
            }
            // every frequency is Normal (rate 1) in the default config
            for &t0 in starts {
                assert!(s.active(k, 1.0, t0 as f64, &DemoMap::new()).is_some());
            }
        }
    }

    #[test]
    fn events_gpu_is_repeatable() {
        let mut c = WallpaperConfig::default();
        c.supernovae = crate::config::Frequency::Often;
        let cam = Camera::new(&c, 1720.0 / 720.0);
        let demo: DemoMap = [(SUPERNOVA.id, 100.0), (COMET.id, 100.0)].into_iter().collect();
        let s = EventSchedule::new(1);
        let a = s.gpu_with_demo(130.0, &c, &cam, 720, &demo);
        // the second call hits the placement cache; it must agree with a fresh schedule
        let b = s.gpu_with_demo(130.0, &c, &cam, 720, &demo);
        let fresh = EventSchedule::new(1).gpu_with_demo(130.0, &c, &cam, 720, &demo);
        assert_eq!(bytemuck::bytes_of(&a), bytemuck::bytes_of(&b));
        assert_eq!(bytemuck::bytes_of(&a), bytemuck::bytes_of(&fresh));
        assert!(a.sn_dir[3] > 0.0 && a.comet_head[3] > 0.0);
    }

    #[test]
    fn demo_parsing() {
        let m = parse_demo("17:5,bad,1:20.5");
        assert_eq!(m.get(&17), Some(&5.0));
        assert_eq!(m.get(&1), Some(&20.5));
        assert_eq!(m.len(), 2);
    }
}
