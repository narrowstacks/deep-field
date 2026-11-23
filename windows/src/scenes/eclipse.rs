//! The eclipse scene's SceneParams builder (MARK: Eclipse in Scenes/SceneParams.swift), with the
//! option data it needs that config.rs doesn't carry (EclipseWorld/EclipseSkyBody's shader
//! values, EclipseAirPreset from Config/Options.swift).
#![allow(dead_code)]

use std::f64::consts::PI;
use std::sync::OnceLock;

use glam::{DVec2, DVec3};

use crate::camera::Camera;
use crate::config::{EclipseMotion, EclipseSkyBody, EclipseWorld, WallpaperConfig};
use crate::events::{self, DemoMap, EventSchedule, Kind};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, smoothstep, v4w};
use crate::palette::{level, rgb, Rgb, Tuned};

// MARK: Option data (Config/Options.swift)

fn world_shader_index(w: EclipseWorld) -> f32 {
    match w {
        EclipseWorld::Rock => 0.0,
        EclipseWorld::Ice => 1.0,
        EclipseWorld::Desert => 2.0,
        EclipseWorld::Basalt => 3.0,
    }
}

/// Surface color (shader light) before the ground color tint.
fn world_base(w: EclipseWorld) -> [f32; 3] {
    match w {
        EclipseWorld::Rock => [0.62, 0.58, 0.54],
        EclipseWorld::Ice => [0.56, 0.66, 0.78],
        EclipseWorld::Desert => [0.8, 0.42, 0.22],
        EclipseWorld::Basalt => [0.15, 0.14, 0.145],
    }
}

fn body_shader_index(b: EclipseSkyBody) -> f32 {
    match b {
        EclipseSkyBody::TealGiant => 0.0,
        EclipseSkyBody::BandedGiant => 1.0,
        EclipseSkyBody::RingedGiant => 2.0,
        EclipseSkyBody::IceGiant => 3.0,
        EclipseSkyBody::RockyMoon => 4.0,
        EclipseSkyBody::NoBody => 5.0,
    }
}

/// Base color (shader light) before the planet color tint.
fn body_base(b: EclipseSkyBody) -> [f32; 3] {
    match b {
        EclipseSkyBody::TealGiant => [0.3, 0.7, 0.85],
        EclipseSkyBody::BandedGiant => [1.0, 0.8, 0.56],
        EclipseSkyBody::RingedGiant => [0.95, 0.84, 0.62],
        EclipseSkyBody::IceGiant => [0.55, 0.8, 0.95],
        EclipseSkyBody::RockyMoon | EclipseSkyBody::NoBody => [0.62, 0.59, 0.55],
    }
}

/// Its size at size 1, relative to the teal giant (the rings reach well past the planet).
fn body_scale(b: EclipseSkyBody) -> f64 {
    match b {
        EclipseSkyBody::RingedGiant => 0.5,
        EclipseSkyBody::RockyMoon => 0.55,
        EclipseSkyBody::IceGiant => 0.8,
        _ => 1.0,
    }
}

/// Air compositions for the eclipse scene's world: sky color, density, haze and clouds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EclipseAirPreset {
    pub name: &'static str,
    pub color: Rgb,
    pub density: f64,
    pub haze: f64,
    pub clouds: f64,
}

impl EclipseAirPreset {
    pub const ALL: [EclipseAirPreset; 4] = [
        EclipseAirPreset { name: "Earth-like", color: rgb(0.36, 0.6, 1.0), density: 1.0, haze: 0.15, clouds: 0.5 },
        EclipseAirPreset { name: "Mars-like", color: rgb(0.88, 0.64, 0.42), density: 0.35, haze: 0.8, clouds: 0.1 },
        EclipseAirPreset { name: "Titan-like", color: rgb(1.0, 0.58, 0.18), density: 2.2, haze: 1.4, clouds: 0.25 },
        EclipseAirPreset { name: "Sulfur", color: rgb(1.0, 0.93, 0.55), density: 1.3, haze: 0.6, clouds: 0.6 },
    ];

    pub fn matches(&self, c: &WallpaperConfig) -> bool {
        c.eclipse_air_color == self.color && c.eclipse_air_density == self.density
            && c.eclipse_air_haze == self.haze && c.eclipse_clouds == self.clouds
    }

    pub fn apply(&self, c: &mut WallpaperConfig) {
        c.eclipse_air_color = self.color;
        c.eclipse_air_density = self.density;
        c.eclipse_air_haze = self.haze;
        c.eclipse_clouds = self.clouds;
    }
}

// MARK: Eclipse geometry

/// The occluder's limb relief (mountains +, valleys -); mirrors ecLimb in eclipse.wgsl.
pub fn eclipse_limb(a: f64) -> f64 {
    let hills = 0.35 * (7.0 * a + 1.3).sin() + 0.2 * (13.0 * a + 0.4).sin() + 0.1 * (29.0 * a + 2.1).sin();
    let n1 = (11.0 * a + 0.7).sin().max(0.0).powi(12);
    let n2 = (17.0 * a + 2.9).sin().max(0.0).powi(12);
    let n3 = (23.0 * a + 4.4).sin().max(0.0).powi(16);
    hills - 1.3 * (n1 + 0.8 * n2 + 0.7 * n3)
}
pub const ECLIPSE_MOUNT: f64 = 0.012;
/// The occluder's radius, in sun radii.
pub const ECLIPSE_OCCLUDER: f64 = 1.06;

/// The occluder's offset from the sun (sun radii) at cycle phase u: it lingers near the middle,
/// so totality and the beads either side of it last, then speeds off. a sinh(b (u - 1/2)) runs
/// from -8 to 8 radii, far enough out that the jump back at the cycle's end isn't seen.
pub fn eclipse_offset(u: f64) -> DVec2 {
    let b: f64 = 15.2;
    let a = 8.0 / (b / 2.0).sinh();
    let x = a * (b * (u - 0.5)).sinh();
    let path: f64 = -0.32; // the path's slant across the sun, radians
    let along = DVec2::new(path.cos(), path.sin());
    let across = DVec2::new(-path.sin(), path.cos());
    along * x + across * 0.018
}

/// The share of the sun left uncovered for offset o, and the middle of that light (sun radii),
/// integrated round the occluder's (mountainous) limb: along each direction from its center,
/// the uncovered stretch is from its limb, or where the ray enters the sun, to where it leaves.
/// A sky body in front of the sun (`body`: its center and radius, sun radii) also hides the
/// part of each stretch that crosses its disk.
pub fn eclipse_exposure(o: DVec2, body: Option<DVec3>) -> (f64, DVec2) {
    let n = 720;
    let mut area = 0.0;
    let mut moment = DVec2::ZERO;
    let oo = o.dot(o);
    let w = body.map(|b| o - DVec2::new(b.x, b.y)).unwrap_or(DVec2::ZERO);
    for i in 0..n {
        let a = i as f64 / n as f64 * 2.0 * PI;
        let u = DVec2::new(a.cos(), a.sin());
        let b = o.dot(u);
        let disc = b * b - oo + 1.0;
        if !(disc > 0.0) {
            continue;
        }
        let t2 = -b + disc.sqrt();
        let t1 = (-b - disc.sqrt()).max(0.0);
        let t0 = t1.max(ECLIPSE_OCCLUDER + ECLIPSE_MOUNT * eclipse_limb(a));
        if !(t2 > t0) {
            continue;
        }
        let mut a2 = (t2 * t2 - t0 * t0) / 2.0;
        let mut a3 = (t2 * t2 * t2 - t0 * t0 * t0) / 3.0;
        if let Some(body) = body {
            let bb = w.dot(u);
            let db = bb * bb - w.dot(w) + body.z * body.z;
            if db > 0.0 {
                let c0 = t0.max(-bb - db.sqrt());
                let c1 = t2.min(-bb + db.sqrt());
                if c1 > c0 {
                    a2 -= (c1 * c1 - c0 * c0) / 2.0;
                    a3 -= (c1 * c1 * c1 - c0 * c0 * c0) / 3.0;
                }
            }
        }
        area += a2;
        moment += o * a2 + u * a3;
    }
    let da = 2.0 * PI / n as f64;
    area *= da;
    moment *= da;
    if area <= 1e-12 {
        return (0.0, o);
    }
    ((area / PI).min(1.0), moment / area)
}

/// Where totality starts and ends in the cycle (phase 0..1), found once by bisection.
pub fn eclipse_totality() -> (f64, f64) {
    static TOT: OnceLock<(f64, f64)> = OnceLock::new();
    *TOT.get_or_init(|| {
        let total = |u: f64| eclipse_exposure(eclipse_offset(u), None).0 <= 0.0;
        let (mut lo, mut hi) = (0.2, 0.5);
        for _ in 0..30 {
            let m = (lo + hi) / 2.0;
            if total(m) { hi = m } else { lo = m }
        }
        let start = hi;
        lo = 0.5;
        hi = 0.8;
        for _ in 0..30 {
            let m = (lo + hi) / 2.0;
            if total(m) { lo = m } else { hi = m }
        }
        (start, lo)
    })
}

fn f3(v: [f32; 3], w: f32) -> [f32; 4] {
    [v[0], v[1], v[2], w]
}

fn mul3(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] * b[0], a[1] * b[1], a[2] * b[2]]
}

/// The ground and sky body colors tint each type's own surface color: the pick's light over the
/// tuned default's, so the default pick leaves the type's color as it is.
fn tint(pick: Rgb, lvl: f32, tuned: Tuned) -> [f32; 3] {
    let d = tuned.light();
    let l = pick.light3(lvl);
    let den = [d.r.max(0.05), d.g.max(0.05), d.b.max(0.05)];
    [0, 1, 2].map(|i| (l[i] / den[i]).max(0.0).min(3.0))
}

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, width: u32, height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let _ = (width, height);
    let mut p = SceneParamsGpu::default();
    let s = cam.screen_scale;
    let th = 0.5;
    // The horizon dips 8 degrees (see EC_HEIGHT); pitch the view so it sits low on screen.
    let dip = 8.0 / 180.0 * PI;
    let horizon_v = if cam.portrait { (cam.subject_y - 0.55) * s } else { -0.42 };
    let pitch = (-horizon_v * th).atan() - dip;
    // screen position (half screen heights) -> scene direction
    let dir = |x: f64, y: f64| -> DVec3 {
        let r = normalize(DVec3::new(x * th, y * th, 1.0));
        DVec3::new(r.x, r.y * pitch.cos() + r.z * pitch.sin(), -r.y * pitch.sin() + r.z * pitch.cos())
    };
    let sun_pos = if cam.portrait { DVec2::new(0.05 * s, (cam.subject_y + 0.32) * s) } else { DVec2::new(0.75, 0.3) };
    let body = c.eclipse_sky_body;
    let planet_pos = if cam.portrait {
        DVec2::new(c.eclipse_planet_x * 0.9 * s, (cam.subject_y - 0.27 + c.eclipse_planet_y) * s)
    } else {
        DVec2::new(c.eclipse_planet_x * cam.aspect, c.eclipse_planet_y)
    };
    let sun = dir(sun_pos.x, sun_pos.y);
    let tan_sun = 0.125 * th * s;
    p.a = v4w(sun, tan_sun as f32);

    // the occluder's pass (or its parked spot), its uncovered light, and the eye's adaptation
    let hold = c.eclipse_motion == EclipseMotion::Hold;
    let cycle = c.eclipse_cycle_minutes.max(0.5) * 60.0;
    // Swift's truncatingRemainder keeps the dividend's sign, like Rust's %
    let u = if hold { 0.5 } else { (t / cycle + 0.12) % 1.0 };
    let o = eclipse_offset(u);
    // the sky body hides the sun too when it's placed in front of it (it's far beyond our
    // moon's occluder, so its shadow has no parallax across the ground)
    let mut body_disk: Option<DVec3> = None;
    if body != EclipseSkyBody::NoBody {
        let pd = dir(planet_pos.x, planet_pos.y);
        let sx = normalize(DVec3::new(0.0, 1.0, 0.0).cross(sun));
        let sy = sun.cross(sx);
        let along = pd.dot(sun);
        let tan_planet = 0.6 * th * s * c.eclipse_planet_size * body_scale(body);
        if along > 0.0 {
            let bc = DVec2::new(pd.dot(sx), pd.dot(sy)) / along / tan_sun;
            let br = tan_planet / tan_sun;
            if bc.length() < 1.0 + br {
                body_disk = Some(DVec3::new(bc.x, bc.y, br));
            }
        }
    }
    let ex_moon = eclipse_exposure(o, None);
    let ex = if body_disk.is_none() { ex_moon } else { eclipse_exposure(o, body_disk) };
    let e = ex.0;
    // what the body leaves of the light the occluder alone would let through
    let body_share = if ex_moon.0 > 1e-9 { e / ex_moon.0 } else { 1.0 };
    let gain = 2.5 / (0.15 + 0.85 * e.sqrt());
    p.b = [o.x as f32, o.y as f32, ECLIPSE_OCCLUDER as f32, e as f32];
    p.j = [ex.1.x as f32, ex.1.y as f32, gain as f32, e.max(1e-9).log10() as f32];

    p.c = f3(c.eclipse_corona_color.light3(level::ECLIPSE_CORONA), c.eclipse_corona_size as f32);
    p.d = f3(c.eclipse_prominence_color.light3(level::ECLIPSE_PROMINENCE), c.eclipse_prominences as f32);
    p.e = f3(
        mul3(world_base(c.eclipse_world), tint(c.eclipse_ground_color, level::ECLIPSE_GROUND, Tuned::EclipseGround)),
        if c.eclipse_landscape { 1.0 } else { 0.0 },
    );
    let mut lit = 0.0;
    if body != EclipseSkyBody::NoBody {
        let pd = dir(planet_pos.x, planet_pos.y);
        let tan_planet = 0.6 * th * s * c.eclipse_planet_size * body_scale(body);
        p.f = v4w(pd, tan_planet as f32);
        lit = (1.0 + sun.dot(-pd)) / 2.0; // the planet's sunlit share, seen from here
    }
    p.g = f3(
        mul3(body_base(body), tint(c.eclipse_planet_color, level::ECLIPSE_PLANET, Tuned::EclipsePlanet)),
        c.eclipse_corona_brightness as f32,
    );
    // shadow parallax: the occluder is near enough that its umbra on the ground is only a few
    // horizon-distances across, so the light comes back over the horizon first
    p.i = [th as f32, pitch as f32, 0.25, lit as f32];
    if c.eclipse_atmosphere {
        // the sky's color as scattering strength per channel, brightest channel 1
        let a = c.eclipse_air_color;
        let mut lin = [a.r.max(0.02).powf(2.2), a.g.max(0.02).powf(2.2), a.b.max(0.02).powf(2.2)];
        let m = lin[0].max(lin[1]).max(lin[2]).max(1e-3);
        lin = lin.map(|v| v / m);
        p.k = f3(lin, c.eclipse_air_density.max(0.01) as f32);
    }
    p.l = [c.eclipse_air_haze as f32, c.eclipse_clouds as f32, body_shader_index(body), world_shader_index(c.eclipse_world)];

    // Eruptions. Cycling, a scheduled window waits for the next totality, so it plays with the
    // corona out. Held at totality there's no waiting, and they come every few minutes.
    // A demo starts at once.
    let k = if hold {
        Kind { id: events::ECLIPSE_ERUPTION.id, slot: 200.0, chance: 0.75, duration: 150.0 }
    } else {
        events::ECLIPSE_ERUPTION
    };
    if let Some((age, mut rng)) = events.active(k, c.eclipse_events.rate(), t, demo) {
        let tot = eclipse_totality();
        let tot_length = (tot.1 - tot.0) * cycle;
        let mut start = t - age;
        let mut length = if hold { k.duration } else { tot_length.max(60.0) };
        let is_demo = demo.get(&k.id).map(|&s0| t >= s0 && t - s0 < k.duration).unwrap_or(false);
        if !is_demo && !hold {
            // the first totality whose middle is still ahead when the window opens
            let phase0 = start / cycle + 0.12;
            let mut n = phase0.floor();
            if phase0 - n > (tot.0 + tot.1) / 2.0 {
                n += 1.0;
            }
            start = (n + tot.0 - 0.12) * cycle;
            length = tot_length;
        }
        let f = (t - start) / length;
        if f >= 0.0 && f < 1.0 {
            // leave the sun upward or sideways, into open sky; held, anywhere off the horizon
            let ang = if hold { rng.range(-0.4, 3.5) } else { rng.range(0.9, 2.6) };
            let bright = smoothstep(0.0, 0.04, f) * (1.0 - smoothstep(0.85, 1.0, f));
            p.h = [ang as f32, f as f32, bright as f32, rng.range(0.0, 50.0) as f32];
            // most lift a big prominence; some are a bare, faster ejection with a small core
            let style: f32 = if rng.next() < 0.65 { 0.0 } else { 1.0 };
            p.m = [style, rng.range(0.75, 1.25) as f32, 0.0, 0.0];
        }
    }
    p.m[2] = ex_moon.0 as f32;
    p.m[3] = body_share as f32;
    // the ground's detail is judged in screen pixels, so it doesn't change with pixel size
    p.n = [c.pixel_size.max(1) as f32, 0.0, 0.0, 0.0];
    p
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totality_brackets_the_middle() {
        let (a, b) = eclipse_totality();
        assert!(a < 0.5 && b > 0.5 && a > 0.2 && b < 0.8);
        assert_eq!(eclipse_exposure(eclipse_offset(0.5), None).0, 0.0);
        assert!(eclipse_exposure(eclipse_offset(0.0), None).0 > 0.999);
    }
}
