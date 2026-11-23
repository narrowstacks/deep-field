//! The rogue planet's SceneParams builder (Scenes/SceneParams.swift, MARK: Rogue planet).

use std::f64::consts::PI;

use glam::{DVec2, DVec3};

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, v3w, v4w};
use crate::palette::level;

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    // the scene's own frame: camera at the origin, looking down +z; the planet has radius 1
    let th = cam.tan_half;
    // it drifts slowly against the stars, covering and uncovering them as it goes
    let dx = 0.05 * (2.0 * PI * t / 1300.0).sin() + 0.02 * (2.0 * PI * t / 530.0 + 1.3).sin();
    let dy = 0.03 * (2.0 * PI * t / 1900.0 + 0.7).sin();
    let aim = normalize(DVec3::new(c.rogue_center_x * cam.aspect * th + dx * th, (c.rogue_center_y + dy) * th, 1.0));
    let alpha = (0.55 * c.rogue_size * th).atan();          // angular radius
    let center = aim / alpha.sin();
    let axis = normalize(DVec3::new(-0.32, 0.88, -0.3));
    let spin = 2.0 * PI * t / 1000.0 * c.rogue_spin;
    // the magnetic axis leans off the spin axis and turns with the planet, so the aurorae wobble
    let toward_us = DVec3::new(0.0, 0.0, -1.0);
    let e1 = normalize(toward_us - axis * toward_us.dot(axis));
    let e2 = axis.cross(e1);
    let tilt = 14.0 / 180.0 * PI;
    let mag = tilt.cos() * axis + tilt.sin() * ((spin + 0.6).cos() * e1 + (spin + 0.6).sin() * e2);
    p.a = v4w(center, 1.0);
    p.b = v4w(axis, spin as f32);
    p.c = v4w(mag, c.rogue_aurora as f32);
    p.d = v3w(c.rogue_aurora_low.light3(level::ROGUE_AURORA), c.rogue_rift as f32);
    p.e = v3w(c.rogue_aurora_high.light3(level::ROGUE_AURORA), c.rogue_milky_way as f32);
    p.f = v3w(c.rogue_rift_color.light3(level::ROGUE_RIFT), 5.3);
    // the Milky Way: a great circle from lower left to upper right, its bright center just
    // beside the planet so the planet's thin air scatters its light into a rim
    let dir = |u: f64, v: f64| normalize(DVec3::new(u * cam.aspect * th, v * th, 1.0));
    let gc = dir(0.62, 0.2);
    let band = normalize(dir(-1.1, -0.75).cross(gc));
    p.i = v4w(band, 0.0);
    p.j = v4w(gc, alpha.tan() as f32);
    if c.rogue_moon {
        // a small moon on a tipped orbit that carries it in front of and behind the planet
        let a = 2.2 + 2.0 * PI * t / (17.0 * 60.0);
        let tip: f64 = 0.32;
        let ax = normalize(DVec3::new(0.15, 1.0, 0.1));
        let u = normalize(ax.cross(DVec3::new(0.0, 0.0, 1.0)));
        let w = u.cross(ax);
        let pos = center + 3.4 * (a.cos() * u + a.sin() * (tip.cos() * w + tip.sin() * ax));
        p.g = v4w(pos, 0.2);
    }
    if let Some((age, mut rng)) = events.active(events::STAR_GLINT, c.rogue_events.rate(), t, demo) {
        // a bright background star passes behind the planet (in planet radii from its center,
        // on the sky): first a glint on one limb, a ring of light all round when it lines up,
        // then a glint on the far limb
        let u = age / events::STAR_GLINT.duration;
        let ang = rng.range(0.0, 2.0 * PI);
        let miss = rng.range(-0.3, 0.3);
        let along = DVec2::new(ang.cos(), ang.sin());
        let across = DVec2::new(-ang.sin(), ang.cos());
        let pos = across * miss + along * (1.6 - 3.2 * u);
        let fade = (u / 0.06).min(1.0) * ((1.0 - u) / 0.06).min(1.0);
        p.h = [pos.x as f32, pos.y as f32, fade as f32, rng.range(0.0, 1.0) as f32];
    }
    p
}
