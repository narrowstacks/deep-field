//! The quasar scene's SceneParams builder (Scenes/SceneParams.swift, MARK: Quasar).
#![allow(unused_variables)]

use std::f64::consts::PI;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, smoothstep, v3w, v4w};
use crate::palette::level;

/// Optical depth of the quasar's dusty torus along the line from the nucleus at angle `i`
/// from the jet axis; mirrors the smooth part of qsrTorus (the clumps average to about 1).
pub fn quasar_torus_depth(i: f64) -> f64 {
    let (r, a, k, n) = (0.55, 0.22, 5.0, 96);
    let ds = 1.0 / n as f64;
    (0..n).fold(0.0, |sum, step| {
        let s = (step as f64 + 0.5) * ds * 1.5;
        let rho = s * i.sin();
        let h = s * i.cos();
        sum + k * (-((rho - r) * (rho - r) + h * h) / (a * a)).exp() * ds * 1.5
    })
}

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, width: u32, height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let tau = 2.0 * PI;
    // the jet axis, from its angle to our line of sight and its direction on screen;
    // in portrait the jets run up the tall frame instead
    let i = c.quasar_view / 180.0 * PI;
    let pa = (if cam.portrait { 90.0 - c.quasar_jet_angle } else { c.quasar_jet_angle }) / 180.0 * PI;
    let axis = normalize(i.sin() * (pa.cos() * cam.right + pa.sin() * cam.up) - i.cos() * cam.fwd);
    let e1 = normalize(axis.cross(cam.fwd));
    let l = 11.5 * c.quasar_jet_length;

    // Relativistic beaming: plasma at Lorentz factor 3 seen at angle i. The approaching jet's
    // light is Doppler boosted by delta^(2 + alpha), the receding one's dimmed. Knots also
    // appear to move faster on the approaching side (superluminal at moderate angles).
    let gamma: f64 = 3.0;
    let beta = (1.0 - 1.0 / (gamma * gamma)).sqrt();
    let mu = i.cos();
    let d_a = 1.0 / (gamma * (1.0 - beta * mu));
    let d_r = 1.0 / (gamma * (1.0 + beta * mu));
    let beam_r = (d_r / d_a).powf(2.6).max(0.02);
    let beam_a = (d_a / 0.55).powf(0.5).min(2.0); // held near 1 so a near-on view doesn't blow out
    let base = 0.075 * c.quasar_knot_speed; // jet lengths per second along the axis
    let period = 1.4 * 4096.0;
    let travel_a = (t * base / (1.0 - beta * mu)) % period;
    let travel_r = (t * base / (1.0 + beta * mu)) % period;

    // the flare: the core brightens sharply and launches a new knot up both jets
    let (mut boost, mut zf_a, mut zf_r, mut flare_knot, mut hot_boost) = (0.0, -1.0, -1.0, 0.0, 0.0);
    if let Some((age, _)) = events.active(events::QUASAR_FLARE, c.quasar_events.rate(), t, demo) {
        let d = events::QUASAR_FLARE.duration;
        boost = 7.0 * smoothstep(0.0, 1.2, age) * (-age / 10.0).exp() + 0.6 * (-age / 45.0).exp();
        let f = (age - 2.0).max(0.0) / (d * 0.78);
        zf_a = l * f.min(1.05);
        zf_r = zf_a * (1.0 - beta * mu) / (1.0 + beta * mu);
        flare_knot = smoothstep(1.0, 5.0, age) * (1.0 - 0.45 * f.min(1.0)) * (1.0 - smoothstep(0.92, 1.04, f));
        hot_boost = 2.5 * smoothstep(0.85, 1.0, f) * (1.0 - smoothstep(0.0, d * 0.2, age - d * 0.8));
    }

    p.a = v4w(axis, l as f32);
    p.b = v4w(e1, travel_a as f32);
    p.c = v3w(c.quasar_jet_color.light3(level::QUASAR_JET), travel_r as f32);
    p.d = v3w(c.quasar_lobe_color.light3(level::QUASAR_LOBE), c.quasar_jet_brightness as f32);
    let spiral = tau / (8.0 * 60.0) * 0.55; // arm pattern speed, corotating at mid-disk
    p.e = [beam_a as f32, beam_r as f32, c.quasar_galaxy as f32, ((t * spiral) % tau) as f32];
    p.f = [boost as f32, zf_a as f32, flare_knot as f32, zf_r as f32];
    // the helix pattern drifts outward; the torus hides the core more as we see it edge-on
    let to_us = normalize(cam.pos);
    let view_angle = to_us.dot(axis).clamp(-1.0, 1.0).acos();
    p.g = [((t * 0.09) % tau) as f32, ((t * 0.004) % 500.0) as f32,
           hot_boost as f32, (-quasar_torus_depth(view_angle)).exp() as f32];
    p
}
