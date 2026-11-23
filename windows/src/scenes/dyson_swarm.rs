//! The Dyson swarm's SceneParams builder (Scenes/SceneParams.swift, MARK: Dyson swarm).

use glam::DVec3;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, v3w, v4w};
use crate::palette::level;

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    // the scene's own frame: camera at the origin, looking down +z; the star is 1 unit across
    let (r0, r1) = (1.7, 4.3);
    let aim = normalize(DVec3::new(0.0, cam.subject_y * cam.tan_half, 1.0));
    let center = aim * 19.0;
    let rings = c.dyson_rings.max(3).min(20);
    let sc = c.dyson_star.color();
    p.a = v4w(center, 1.0);
    p.b = [sc.r, sc.g, sc.b, 4.5];
    // the innermost ring's orbit phase; outer rings scale it by Kepler's law in the shader
    let phase = t * c.dyson_orbit_speed * 0.012;
    p.c = [rings as f32, c.dyson_density.max(0.0).min(1.0) as f32, c.dyson_glint as f32, phase as f32];
    p.d = v3w(c.dyson_panel_a.light3(level::DYSON_PANEL), 3.7);
    p.e = v3w(c.dyson_panel_b.light3(level::DYSON_PANEL), r0 as f32);
    p.f = v3w(c.dyson_heat.light3(level::DYSON_HEAT), r1 as f32);
    if let Some((age, mut rng)) = events.active(events::SWARM_WAVE, c.dyson_events.rate(), t, demo) {
        // a wave of panels on three neighboring rings in the outer half turns to face us
        let half = (rings / 2) as f64;
        let ring = (half + (rng.next() * half).floor()).min((rings - 3) as f64);
        p.g = [ring as f32, age as f32, 26.0, 1.0];
    }
    p
}
