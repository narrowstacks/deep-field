//! The ringed planet's SceneParams (Scenes/SceneParams.swift, MARK: Ringed planet).

use std::f64::consts::PI;

use glam::DQuat;

use crate::camera::{Camera, SceneGeometry};
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, v3w, v4w};
use crate::palette::level;

struct Moon {
    orbit: f64,
    period: f64,
    radius: f64,
    phase: f64,
    tip: f64,
}

#[allow(unused_variables)]
pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, width: u32, height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let to_cam = -cam.center();
    // the spin axis: screen up, tipped toward us to open the rings, then slanted
    let open = c.ringed_tilt / 180.0 * PI;
    let axis0 = normalize(open.cos() * cam.up + open.sin() * to_cam);
    let axis = normalize(DQuat::from_axis_angle(to_cam, c.ringed_roll / 180.0 * PI).mul_vec3(axis0));
    // The sun, set against the ring plane: `ringedSun` degrees round from us (off to the
    // right), `ringedSunHeight` degrees above the plane. Lower than our own view of the rings,
    // their shadow falls across the side of the planet we see.
    let phase = c.ringed_sun / 180.0 * PI;
    let height = c.ringed_sun_height / 180.0 * PI;
    let c1 = normalize(to_cam - axis * to_cam.dot(axis));
    let mut c2 = axis.cross(c1);
    if c2.dot(cam.right) < 0.0 {
        c2 = -c2;
    }
    let sun = normalize(height.cos() * (phase.cos() * c1 + phase.sin() * c2) + height.sin() * axis);
    let r = 4.4 * c.ringed_size;
    p.a = v4w(axis, r as f32);
    p.b = v4w(sun, 1.05);
    p.c = v3w(c.ringed_band_light.light3(level::RINGED_BAND), 0.0);
    p.d = v3w(c.ringed_band_dark.light3(level::RINGED_BAND), 0.0);
    p.e = v3w(c.ringed_ring_color.light3(level::RINGED_RING), 0.0);
    p.i = [c.ringed_bands as f32, c.ringed_turbulence as f32, c.ringed_wind as f32, 0.0];
    p.j = [c.ringed_ring_style.shader_index(), c.ringed_ring_width as f32, c.ringed_ring_density as f32,
           if c.ringed_spokes { 1.0 } else { 0.0 }];

    // Up to three moons outside the rings. e1 points our way in the ring plane. The inner moon's
    // orbit is tipped so its near side rises across the face of the planet, casting its shadow
    // on the clouds as it goes.
    let e1 = normalize(axis.cross(cam.right));
    let e2 = axis.cross(e1);
    let moons = [Moon { orbit: 2.75, period: 7.0, radius: 0.045, phase: 1.3, tip: 14.5 },
                 Moon { orbit: 3.9, period: 16.0, radius: 0.075, phase: 4.1, tip: -3.0 },
                 Moon { orbit: 5.3, period: 34.0, radius: 0.06, phase: 2.4, tip: 7.0 }];
    let count = c.ringed_moon_count.clamp(0, 3) as usize;
    for (i, m) in moons.iter().take(count).enumerate() {
        let a = m.phase + 2.0 * PI * t * c.ringed_moon_speed / (m.period * 60.0);
        let tip = m.tip / 180.0 * PI;
        let pos = r * m.orbit * (a.cos() * (tip.cos() * e1 + tip.sin() * axis) + a.sin() * e2);
        let v = v4w(pos, (r * m.radius * c.ringed_moon_size) as f32);
        match i {
            0 => p.f = v,
            1 => p.g = v,
            _ => p.h = v,
        }
    }

    // A great white storm breaks out in one band and spreads round the planet. It's drawn in
    // the bands' drifting frame (see rgDrift in the shader): it appears facing us and then
    // rides the band.
    if let Some((age, mut rng)) = events.active(events::WHITE_STORM, c.ringed_events.rate(), t, demo) {
        let lat: f64 = 0.52;
        let wrap = SceneGeometry::FLOW_PERIOD as f64 * 1000.0;
        let start = (t - age) % wrap;
        let drift = start * c.ringed_wind * (0.0025 + 0.004 * (lat * 19.0).cos());
        let view = normalize(to_cam - axis * to_cam.dot(axis));
        let lon_view = view.dot(e2).atan2(view.dot(e1));
        p.c[3] = (lon_view + drift + rng.range(-0.5, 0.3)) as f32;
        p.d[3] = (age / events::WHITE_STORM.duration).max(0.001) as f32;
    }
    p
}
