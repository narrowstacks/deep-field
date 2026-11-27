//! The planetary nebula's SceneParams (Scenes/SceneParams.swift, MARK: Planetary nebula).

use std::f64::consts::PI;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, smoothstep, v3w, v4w};
use crate::palette::level;

#[allow(unused_variables)]
pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, width: u32, height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    // the barrel's axis: tipped away from our line of sight toward the upper right
    let view = cam.center();
    let lean = c.planetary_view / 180.0 * PI;
    let turn: f64 = 0.6;
    let side = turn.cos() * cam.right + turn.sin() * cam.up;
    let axis = normalize(lean.cos() * view + lean.sin() * side);
    p.a = v4w(axis, (3.5 * c.planetary_size) as f32);
    p.b = v3w(c.planetary_inner_color.light3(level::PLANETARY_INNER), c.planetary_elongation as f32);
    p.c = v3w(c.planetary_rim_color.light3(level::PLANETARY_RIM), c.planetary_knots as f32);
    p.d = v3w(c.planetary_halo_color.light3(level::PLANETARY_HALO), if c.planetary_halo { 1.0 } else { 0.0 });
    p.e[1] = 3.7;
    let mut star = 1.0;
    if let Some((age, _)) = events.active(events::SHELL_EJECTION, c.planetary_events.rate(), t, demo) {
        let f = age / events::SHELL_EJECTION.duration;
        // the star flares as it lets go, then the shell coasts outward, slowing and thinning
        star += 2.5 * smoothstep(0.0, 0.02, f) * (-f / 0.06).exp();
        p.e[2] = (0.06 + 0.9 * (1.0 - (-f * 2.2).exp())) as f32;
        p.e[3] = (smoothstep(0.0, 0.04, f) * (1.0 - smoothstep(0.55, 1.0, f)) * (1.4 - 0.8 * f)) as f32;
    }
    p.f = [0.75, 0.88, 1.0, star as f32];
    p
}
