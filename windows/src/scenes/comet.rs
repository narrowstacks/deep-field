//! The comet's SceneParams builder (SceneParams.comet in Scenes/SceneParams.swift).

use std::f64::consts::PI;

use glam::DVec2;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{smoothstep, v3w};
use crate::palette::level;

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let rate = c.comet_events.rate();
    let (mut outburst, mut shell_radius, mut shell_bright) = (0.0, 0.0, 0.0);
    if let Some((age, _)) = events.active(events::COMET_OUTBURST, rate, t, demo) {
        outburst = smoothstep(0.0, 3.0, age) * (-age / 30.0).exp();
        // the ejected shell coasts outward, slowing as it spreads, and fades as it thins
        shell_radius = 0.32 * (1.0 - (-age / 25.0).exp());
        let dur = events::COMET_OUTBURST.duration;
        shell_bright = smoothstep(0.0, 2.0, age) * (-age / 22.0).exp() * 1.2
            * (1.0 - smoothstep(dur - 15.0, dur, age));
    }
    let (mut disconnect_pos, mut disconnect_strength) = (-1.0, 0.0);
    if let Some((age, _)) = events.active(events::TAIL_DISCONNECT, rate, t, demo) {
        let f = age / events::TAIL_DISCONNECT.duration;
        disconnect_pos = 0.08 + 1.4 * f * c.comet_tail_length;
        disconnect_strength = smoothstep(0.0, 0.1, f) * (1.0 - smoothstep(0.75, 1.0, f));
    }
    // head lower right, tails streaming up and to the left, away from an off-screen sun;
    // in portrait the tails rise more steeply, up through the tall frame
    let s = cam.screen_scale;
    let head = if cam.portrait { DVec2::new(0.3 * cam.aspect * s, cam.subject_y * s) } else { DVec2::new(0.42 * cam.aspect, -0.32) };
    let ion = if cam.portrait { DVec2::new(-0.4, 0.92) } else { DVec2::new(-0.94, 0.36) };
    let ion = ion * (1.0 / ion.length());
    p.a = [head.x as f32, head.y as f32, c.comet_activity as f32, c.comet_tail_length as f32];
    p.b = [ion.x as f32, ion.y as f32, 0.35, outburst as f32];
    p.c = v3w(c.comet_ion_color.light3(level::COMET_ION), disconnect_pos as f32);
    p.d = v3w(c.comet_dust_color.light3(level::COMET_DUST), disconnect_strength as f32);
    // Swift's truncatingRemainder keeps the sign of the dividend, like Rust's %
    p.e = [shell_radius as f32, ((t * 0.25) % (2.0 * PI)) as f32, shell_bright as f32, 0.0];
    p
}
