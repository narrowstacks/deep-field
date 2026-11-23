//! Per-frame uniforms worked out on the CPU (Scenes/SceneParams.swift, plus the FrameParams and
//! BakeParams the macOS Renderer fills in).
#![allow(dead_code)]

use std::f64::consts::PI;

use glam::DVec3;

use crate::camera::{Camera, SceneGeometry};
use crate::config::{SceneKind, WallpaperConfig};
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::{BakeParams, FrameParams, SceneParamsGpu};
use crate::math::{normalize, v3w, v4w};
use crate::palette::level;

/// Builds the per-frame `SceneParamsGpu` slots for the scenes whose state is computed on the CPU.
/// Scenes without CPU state (black hole, binary, ...) get the zeroed default.
#[allow(clippy::too_many_arguments)]
pub fn build(c: &WallpaperConfig, elapsed: f64, cam: &Camera, width: u32, height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    use crate::scenes::*;
    let t = elapsed;
    let (w, h) = (width, height);
    match c.scene {
        SceneKind::GasGiant => gas_giant(c, t, cam, events, demo),
        SceneKind::TidalDisruption => tidal_disruption::build(c, t, cam, w, h, events, demo),
        SceneKind::Pulsar => pulsar::build(c, t, cam, w, h, events, demo),
        SceneKind::PlanetaryNebula => planetary_nebula::build(c, t, cam, w, h, events, demo),
        SceneKind::RingedPlanet => ringed_planet::build(c, t, cam, w, h, events, demo),
        SceneKind::ProtoplanetaryDisk => protoplanetary_disk::build(c, t, cam, w, h, events, demo),
        SceneKind::NeutronMerger => neutron_merger::build(c, t, cam, w, h, events, demo),
        SceneKind::BlackHoleMerger => black_hole_merger::build(c, t, cam, w, h, events, demo),
        SceneKind::DysonSwarm => dyson_swarm::build(c, t, cam, w, h, events, demo),
        SceneKind::RoguePlanet => rogue_planet::build(c, t, cam, w, h, events, demo),
        SceneKind::Eclipse => eclipse::build(c, t, cam, w, h, events, demo),
        SceneKind::Comet => comet::build(c, t, cam, w, h, events, demo),
        SceneKind::StellarSurface => stellar_surface::build(c, t, cam, w, h, events, demo),
        SceneKind::Quasar => quasar::build(c, t, cam, w, h, events, demo),
        SceneKind::Galaxy => galaxy::build(c, t, cam, w, h, events, demo),
        SceneKind::AuroraOrbit => aurora_orbit::build(c, t, cam, w, h, events, demo),
        SceneKind::LiveEarth => live_earth::build(c, t, cam, w, h),
        // not ported: hidden in the macOS app too
        SceneKind::Nebula => SceneParamsGpu::default(),
        // no CPU-side scene state in Swift either
        SceneKind::BlackHole | SceneKind::Wormhole | SceneKind::Binary | SceneKind::Trinary => SceneParamsGpu::default(),
    }
}

// MARK: Gas giant storms

/// Wind speed at latitude sine `sl`, radians of longitude per second; mirrors the shader's ggWind.
pub fn gas_wind(sl: f64, wind: f64) -> f64 {
    wind * 0.0025 * (0.75 * (sl * 21.0).sin() + 0.35 * (sl * 8.0).cos() + 0.25)
}

fn gas_giant(c: &WallpaperConfig, t: f64, cam: &Camera, events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    // the scene's own frame: camera at the origin, looking down +z
    let r: f64 = 1.0;
    let aim = normalize(DVec3::new(c.gas_center_x * cam.aspect * cam.tan_half, c.gas_center_y * cam.tan_half, 1.0));
    let center = aim * c.gas_distance * r;
    let lean = c.gas_tilt / 180.0 * PI;
    let axis = normalize(DVec3::new(lean.sin(), lean.cos(), -0.22));
    let phase = c.gas_sun / 180.0 * PI;
    let sun = normalize(phase.cos() * DVec3::new(0.0, 0.0, -1.0) + phase.sin() * normalize(DVec3::new(-0.95, 0.3, 0.0)));
    p.a = v4w(center, r as f32);
    p.b = v4w(axis, c.gas_wind as f32);
    p.c = v4w(sun, c.gas_turbulence as f32);
    p.d = v3w(c.gas_zone.light3(level::GAS_CLOUD), c.gas_storm_size as f32);
    p.e = v3w(c.gas_belt.light3(level::GAS_CLOUD), 40.0);
    p.f = v3w(c.gas_storm.light3(level::GAS_CLOUD), c.gas_lightning.rate() as f32);
    p.i[0] = 4.3;
    let toward_us = DVec3::new(0.0, 0.0, -1.0);
    let e1 = normalize(toward_us - axis * toward_us.dot(axis));
    let e2 = axis.cross(e1);
    if c.gas_moon {
        // a small moon whose orbit carries it across the face of the planet
        let a = 0.9 + 2.0 * PI * t / (6.0 * 60.0);
        let tip = 8.0 / 180.0 * PI;
        let pos = center + 2.1 * r * (a.cos() * (tip.cos() * e1 + tip.sin() * axis) + a.sin() * e2);
        p.g = v4w(pos, (0.045 * r) as f32);
    }
    if let Some((age, mut rng)) = events.active(events::COMET_IMPACT, c.gas_events.rate(), t, demo) {
        // a fragment train hits a band on the side facing us
        let sl: f64 = 0.47;
        let lon = rng.range(-0.5, 0.1);
        let cl = (1.0 - sl * sl).sqrt();
        let site = axis * sl + (e1 * lon.cos() + e2 * lon.sin()) * cl;
        p.h = v4w(site, (age / events::COMET_IMPACT.duration).max(0.0005) as f32);
    }
    p
}

// MARK: Merger clocks (needed by the event listing)

/// Seconds before the merger that a demo (the merger event) starts from.
pub const MERGER_LEAD: f64 = 12.0;

/// The merger cycle at time t. Each cycle starts with a merger (u = 0) and ends with the next one.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MergerClock {
    pub u: f64,
    pub cycle: f64,
    pub index: f64,
}

impl MergerClock {
    pub fn post(&self) -> f64 { (self.cycle * 0.3).min(70.0) }
    pub fn tau(&self) -> f64 { self.cycle - self.u }
    pub fn tau_a(&self) -> f64 { self.cycle * 0.62 }
    pub fn tau_c(&self) -> f64 { self.cycle * 0.22 }
}

pub fn merger_clock(c: &WallpaperConfig, t: f64, demo: &DemoMap) -> MergerClock {
    cycle_clock(c.merger_cycle_minutes, t, demo.get(&events::NEUTRON_MERGER.id).copied())
}

fn cycle_clock(minutes: f64, t: f64, demo_start: Option<f64>) -> MergerClock {
    let cycle = (minutes * 60.0).max(120.0);
    // so a launch opens on the remnant, not a flash
    let mut u = t + cycle * 0.3;
    if let Some(s) = demo_start {
        if t >= s {
            u = cycle - MERGER_LEAD + (t - s);
        }
    }
    let index = (u / cycle).floor();
    MergerClock { u: u - index * cycle, cycle, index }
}

/// The black hole merger's own speed: every motion in it, the merger cycle included.
pub fn bbh_speed(c: &WallpaperConfig) -> f64 {
    c.bbh_speed.max(0.1).min(4.0)
}

pub fn bbh_clock(c: &WallpaperConfig, t: f64, demo: &DemoMap) -> MergerClock {
    let v = bbh_speed(c);
    let k = cycle_clock(c.bbh_cycle_minutes, t * v, demo.get(&events::BLACK_HOLE_MERGER.id).map(|s| s * v));
    // Slow motion round the merger: the last second of the chirp and the ringdown play `slow`
    // times slower, easing in and out; the speed bump's integral is a difference of softplus terms.
    let slow = c.bbh_ringdown.max(1.0).min(8.0);
    if !(slow > 1.001) {
        return k;
    }
    let before = 1.0 * slow;
    let after = 1.6 * slow;
    let soft = 1.0;
    let softplus = |v: f64| if v > 30.0 { v } else { (1.0 + v.exp()).ln() };
    let h = |x: f64| soft * (softplus((x + before) / soft) - softplus((x - after) / soft));
    let warp = |x: f64| x - (1.0 - 1.0 / slow) * (h(x) - h(0.0));
    let half = k.cycle / 2.0;
    let cycle = warp(half) - warp(-half);
    let u = if k.u < half { warp(k.u) } else { cycle + warp(k.u - k.cycle) };
    MergerClock { u, cycle, index: k.index }
}

// MARK: Frame and bake uniforms (Renderer.encodeFrame / encodeBake)

/// Lensed scenes find their planets through the baked orbit-shell crossings.
pub fn needs_shells(c: &WallpaperConfig) -> bool {
    c.scene.lensing() > 0.0 && c.scene.has_planets() && c.planet_count > 0
}

/// The star meets black hole disk's fixed outer radius (TDEGeometry.diskOuter).
pub const TDE_DISK_OUTER: f64 = 13.0;

/// `BakeParams` as Renderer.encodeBake fills it.
pub fn bake_params(c: &WallpaperConfig, width: u32, height: u32, cam: &Camera) -> BakeParams {
    let shells = needs_shells(c);
    let radii = SceneGeometry::shell_radii();
    BakeParams {
        width: width as f32,
        height: height as f32,
        cam_dist: cam.distance as f32,
        cam_elev: (c.camera_tilt() / 180.0 * PI) as f32,
        tan_half_fov: cam.tan_half as f32,
        disk_in: SceneGeometry::DISK_IN,
        disk_out: if c.scene == SceneKind::TidalDisruption { (TDE_DISK_OUTER * 1.2) as f32 } else { c.disk_size as f32 },
        roll: SceneGeometry::ROLL as f32,
        shell_r0: radii[0],
        shell_r1: radii[1],
        throat: c.throat as f32,
        star_density: c.star_density as f32,
        lensing: c.scene.lensing(),
        galaxies: if c.galaxies { 1.0 } else { 0.0 },
        look_x: cam.look.x as f32,
        look_y: cam.look.y as f32,
        milky_way: if c.milky_way { 1.0 } else { 0.0 },
        nebula_type: c.nebula_type.shader_index(),
        nebula_seed: c.nebula_seed as f32,
        shells: if shells { 1.0 } else { 0.0 },
        // Swift's % keeps the sign of the dividend, like Rust's
        sky_seed: (c.sky_seed % 1_000_000) as f32,
        pad: [0.0; 3],
    }
}

/// `FrameParams` as Renderer.encodeFrame fills it. `planet_count` is the count the scene may
/// show (0 for a lensed scene baked without shells), `bloom_on` whether the bloom passes run.
#[allow(clippy::too_many_arguments)]
pub fn frame_params(c: &WallpaperConfig, cam: &Camera, elapsed: f64, width: u32, height: u32,
                    planet_count: usize, star_count: usize, light_count: usize, bloom_on: bool) -> FrameParams {
    let bloom_amount = c.bloom + c.scene.extra_bloom();
    // the disk animation is periodic in flowPeriod, so time wraps there and keeps Float precision
    let wrap = SceneGeometry::FLOW_PERIOD as f64 * 1000.0;
    let pixel_angle = 2.0 * cam.tan_half / height as f64;
    let radii = SceneGeometry::shell_radii();
    FrameParams {
        time: (elapsed % wrap) as f32,
        levels: c.levels as f32,
        disk_in: SceneGeometry::DISK_IN,
        disk_out: c.disk_size as f32,
        exposure: c.brightness as f32,
        disk_speed: (1.6 * c.disk_speed) as f32,
        flow_period: SceneGeometry::FLOW_PERIOD,
        planet_count: planet_count as f32,
        shell_r0: radii[0],
        shell_r1: radii[1],
        saturation: c.saturation as f32,
        scene: c.scene.shader_index(),
        dither: c.dither.shader_index(),
        twinkle: c.twinkles.rate() as f32,
        pulsars: if c.pulsars { 1.0 } else { 0.0 },
        sky_brightness: c.nebula as f32,
        pixel_angle: pixel_angle as f32,
        star_count: star_count as f32,
        light_count: light_count as f32,
        ring_strength: c.photon_ring as f32,
        nebula_type: c.nebula_type.shader_index(),
        screen_scale: cam.screen_scale as f32,
        twinkle_brightness: c.twinkle_brightness as f32,
        twinkle_speed: c.twinkle_speed as f32,
        cam_pos: [cam.pos.x as f32, cam.pos.y as f32, cam.pos.z as f32, 0.0],
        cam_right: [cam.right.x as f32, cam.right.y as f32, cam.right.z as f32, width as f32],
        cam_up: [cam.up.x as f32, cam.up.y as f32, cam.up.z as f32, height as f32],
        image: [c.contrast as f32, c.black_point as f32, c.highlights as f32, c.vignette as f32],
        bloom: [bloom_amount as f32, c.bloom_threshold as f32, if bloom_on { 1.0 } else { 0.0 }, c.bloom_radius as f32],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gas_giant_slots() {
        let mut c = WallpaperConfig::default();
        c.scene = SceneKind::GasGiant;
        let cam = Camera::new(&c, 1720.0 / 720.0);
        let ev = EventSchedule::new(1);
        let p = build(&c, 300.0, &cam, 1720, 720, &ev, &DemoMap::new());
        assert_eq!(p.a[3], 1.0);
        assert_eq!(p.e[3], 40.0);
        assert_eq!(p.i[0], 4.3);
        // the moon is on by default
        assert!(p.g[3] > 0.0);
        // a demo impact lands on the planet's surface (unit vector)
        let demo: DemoMap = [(events::COMET_IMPACT.id, 290.0)].into_iter().collect();
        let p = build(&c, 300.0, &cam, 1720, 720, &ev, &demo);
        let s = DVec3::new(p.h[0] as f64, p.h[1] as f64, p.h[2] as f64);
        assert!((s.length() - 1.0).abs() < 1e-5);
        assert!((p.h[3] - (10.0 / 360.0) as f32).abs() < 1e-6);
    }

    #[test]
    fn frame_time_wraps() {
        let c = WallpaperConfig::default();
        let cam = Camera::new(&c, 1.6);
        let f = frame_params(&c, &cam, 48_000.0 + 5.0, 1600, 1000, 3, 0, 1, true);
        assert_eq!(f.time, 5.0);
        assert_eq!(f.bloom[0], 0.3);
    }
}
