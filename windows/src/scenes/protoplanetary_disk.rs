//! The protoplanetary disk's SceneParams builder (Scenes/SceneParams.swift, MARK: Protoplanetary disk).

use std::f64::consts::PI;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, smoothstep, v3w, v4w};
use crate::palette::level;

/// An accretion outburst's light curve, `a` seconds after it starts: a soft-edged flash, then a
/// long faint glow. Mirrors pdOutburst in the shader, which uses it for the light echo.
pub fn proto_outburst(a: f64) -> f64 {
    if a <= 0.0 { 0.0 } else { (-(a - 9.0) * (a - 9.0) / 25.0).exp() + 0.12 * smoothstep(0.0, 12.0, a) * (-a / 45.0).exp() }
}

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    // the disk's axis: tipped from our line of sight toward screen up (so the far side shows
    // above the star), then slanted
    let to_cam = -cam.center();
    let incl = c.proto_view / 180.0 * PI;
    let slant = c.proto_slant / 180.0 * PI;
    let side = slant.cos() * cam.up + slant.sin() * cam.right;
    let axis = normalize(incl.cos() * to_cam + incl.sin() * side);
    let sc = side.cross(to_cam);
    let e1 = normalize(sc - axis * sc.dot(axis));
    let r = 8.5 * c.proto_size;
    let w = c.proto_look.weights();
    p.a = v4w(axis, r as f32);
    p.b = v4w(e1, (0.05 + 0.065 * c.proto_flaring) as f32);
    p.c = v3w(c.proto_dust_color.light3(level::PROTO_DUST), c.proto_gap_width as f32);
    p.d = v3w(c.proto_gas_color.light3(level::PROTO_GAS), w[0]);
    p.f = v3w(c.proto_jet_color.light3(level::PROTO_JET), if c.proto_jets { 1.0 } else { 0.0 });
    // the outer edge orbits in 10 minutes at speed 1; the inner rings far faster (Kepler)
    p.g = [c.proto_gaps as f32, 2.3, (2.0 * PI / 600.0 * c.proto_orbit_speed) as f32, 90.0];
    p.h = [-1.0, (r / 35.0) as f32, 6.0, 0.0];
    p.i = [w[1], w[2], 0.0, 0.0];
    let mut star = 1.0;
    if let Some((age, _)) = events.active(events::ACCRETION_OUTBURST, c.proto_events.rate(), t, demo) {
        // FU Orionis style: the inner disk dumps onto the star, which flares; the flash then
        // travels out across the disk as a light echo (the shader delays it by path length)
        p.h[0] = age as f32;
        star += p.h[2] as f64 * proto_outburst(age);
    }
    p.e = v3w(c.proto_star_color.light3(level::PROTO_STAR), star as f32);
    p
}
