//! The galaxy scene's uniforms (Scenes/Galaxy.swift). Swift's SceneParams.build has no galaxy
//! case, so `build` returns the zeroed default; the shader reads `G` instead.
#![allow(unused_variables)]

use std::f64::consts::PI;

use crate::camera::Camera;
use crate::config::{GalaxyType, WallpaperConfig};
use crate::events::{DemoMap, EventSchedule};
use crate::gpu_types::{GalaxyGpu, SceneParamsGpu};
use crate::palette::level;

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, width: u32, height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    SceneParamsGpu::default()
}

/// Circular speed at radius r (fraction of the visible radius), peak normalized to about 1.
/// With a dark matter halo the curve rises and stays flat; without one it falls off like a
/// Kepler orbit past the visible mass (GalaxyModel.velocity, mirrored by the shader).
pub fn velocity(r: f64, dark_matter: bool) -> f64 {
    if dark_matter {
        return 1.0 - (-r / 0.12).exp();
    }
    let a: f64 = 0.08; // Plummer scale of the visible mass
    r / (r * r + a * a).powf(0.75) * a.sqrt() / 0.6204
}

pub fn omega(r: f64, dark_matter: bool, scale: f64) -> f64 {
    scale * velocity(r, dark_matter) / r.max(0.01)
}

/// GalaxyModel.gpu (Scenes/Galaxy.swift): the galaxy scene's uniforms.
pub fn galaxy_gpu(c: &WallpaperConfig, elapsed: f64) -> GalaxyGpu {
    let t = elapsed;
    let tau = 2.0 * PI;
    // velocity scale: with a halo, an edge star completes an orbit in galaxyRotationMinutes
    let scale = tau / (c.galaxy_rotation_minutes * 60.0) / velocity(1.0, true);
    let bar_length = 0.28;
    // corotation: arms at mid-disk, bars just beyond their ends
    let corotation = if c.galaxy_type == GalaxyType::Barred { bar_length * 1.2 } else { 0.55 };
    let pattern_speed = omega(corotation, c.dark_matter, scale);
    let solid_body = omega(0.5, c.dark_matter, scale); // dwarf irregulars rotate nearly rigidly
    let flow_period = c.galaxy_rotation_minutes * 60.0 * 0.15;
    // satellite galaxies orbit out in the halo, at the speed the rotation curve gives there
    // (radii match the shader's `satellite` calls); without dark matter they crawl
    let satellite_angle = |r: f64, phase: f64| ((phase + omega(r, c.dark_matter, scale) * t) % tau) as f32;
    let p = &c.palette;
    GalaxyGpu {
        shape: [c.galaxy_type.shader_index(), c.galaxy_arms as f32,
                (c.galaxy_pitch / 180.0 * PI).tan() as f32, bar_length as f32],
        motion: [((pattern_speed * t) % tau) as f32, scale as f32,
                 if c.dark_matter { 1.0 } else { 0.0 }, flow_period as f32],
        core: p.galaxy_core.light(level::GALAXY_CORE),
        arms: p.galaxy_arms.light(level::GALAXY_ARMS),
        nebula: p.galaxy_nebula.light(level::GALAXY_NEBULA),
        dust: p.galaxy_dust.simd(),
        misc: [(8.5 * c.galaxy_size) as f32, ((solid_body * t) % tau) as f32,
               satellite_angle(1.15, 2.2), satellite_angle(1.6, 4.0)],
    }
}
