//! The pulsar's SceneParams builder (SceneParams.pulsar in Scenes/SceneParams.swift).

use std::f64::consts::PI;

use glam::DVec3;

use crate::camera::Camera;
use crate::config::{PulsarBeams, PulsarFieldStyle, WallpaperConfig};
use crate::events::{DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, v3w, v4w};
use crate::palette::{level, Rgb};

/// PulsarBeams.mask: bit 0 the pole on the spin axis' north side, bit 1 the other.
fn beam_mask(b: PulsarBeams) -> i32 {
    match b {
        PulsarBeams::Both => 3,
        PulsarBeams::Top => 1,
        PulsarBeams::Bottom => 2,
        PulsarBeams::NoBeams => 0,
    }
}

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             _events: &EventSchedule, _demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let tilt = c.pulsar_axis_tilt / 180.0 * PI;
    // spin axis: up, leaning toward the camera
    let spin = normalize(DVec3::new(0.0, tilt.cos(), -tilt.sin()));
    let e1 = normalize(spin.cross(DVec3::new(1.0, 0.0, 0.0)));
    let e2 = spin.cross(e1);
    // Swift's truncatingRemainder keeps the sign of the dividend, like Rust's %
    let phase = ((t / c.pulsar_period.max(0.2)) % 1.0) * 2.0 * PI;
    let alpha = c.pulsar_inclination / 180.0 * PI;
    let m = alpha.cos() * spin + alpha.sin() * (phase.cos() * e1 + phase.sin() * e2);
    let width = c.pulsar_beam_width / 180.0 * PI;
    // The beams wind back behind the rotation (radians per unit of length), more so the
    // faster it spins, like water from a turning hose.
    let trail = (0.08 / c.pulsar_period.max(0.2)).min(0.12) * c.pulsar_beam_trail;
    // lighthouse flash when a beam sweeps across the camera; the part of the beam that
    // reaches us left the star a while ago, so use its wound-back direction
    let to_cam = normalize(cam.pos);
    let lag = -trail * cam.pos.length();
    let mc = lag.cos() * m + lag.sin() * spin.cross(m) + (1.0 - lag.cos()) * spin.dot(m) * spin;
    let beams = beam_mask(c.pulsar_beams);
    let toward = mc.dot(to_cam);
    let facing = if toward >= 0.0 { 1 } else { 2 };           // which beam points our way
    let ang = toward.abs().min(1.0).acos();
    let flash = if beams & facing != 0 { (-(ang / (width * 2.0)).powi(2)).exp() } else { 0.0 };
    let scaled = |col: Rgb, lvl: f32, k: f64, on: bool| -> [f32; 3] {
        if on { col.light3(lvl).map(|v| v * k.max(0.0) as f32) } else { [0.0; 3] }
    };
    let field_style = if !c.pulsar_field_lines { 0.0 } else if c.pulsar_field_style == PulsarFieldStyle::Lines { 1.0 } else { 2.0 };
    p.a = v4w(m, width as f32);
    p.b = v4w(spin, flash as f32);
    p.c = v3w(scaled(c.pulsar_beam_color, level::PULSAR_BEAM, c.pulsar_beam_intensity, true), beams as f32);
    p.d = v3w(scaled(c.pulsar_nebula_color, level::PULSAR_NEBULA, c.pulsar_nebula_intensity, c.pulsar_nebula), field_style);
    p.e = v3w(scaled(c.pulsar_field_color, level::PULSAR_FIELD, c.pulsar_field_intensity, true), trail as f32);
    p.f = v3w(scaled(c.pulsar_ring_color, level::PULSAR_RING, c.pulsar_ring_intensity, c.pulsar_ring), 0.0);
    p
}
