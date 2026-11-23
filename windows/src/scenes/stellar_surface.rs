//! The star close-up's SceneParams builder (SceneParams.stellarSurface in Scenes/SceneParams.swift).

use std::f64::consts::PI;

use glam::DVec2;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{smoothstep, Rng};

/// The stretch of limb that's on screen, as a middle angle and half span (radians), so limb
/// features and events land where they can be seen at any zoom and framing
/// (SceneParams.visibleLimb).
pub fn visible_limb(center: DVec2, radius: f64, half_width: f64, half_height: f64) -> (f64, f64) {
    let n = 180usize;
    let on_screen: Vec<bool> = (0..n).map(|i| {
        let a = i as f64 / n as f64 * 2.0 * PI;
        let pt = center + radius * DVec2::new(a.cos(), a.sin());
        pt.x.abs() < half_width * 0.94 && pt.y.abs() < half_height * 0.94
    }).collect();
    if on_screen.iter().all(|&b| b) {
        return (PI / 2.0, PI);
    }
    // the longest run of on-screen angles, going around the circle
    let (mut best_start, mut best_len, mut start, mut length) = (0usize, 0usize, 0usize, 0usize);
    for i in 0..(2 * n) {
        if !on_screen[i % n] {
            length = 0;
            continue;
        }
        if length == 0 {
            start = i;
        }
        length += 1;
        if length > best_len {
            best_start = start;
            best_len = length;
        }
    }
    if best_len == 0 {
        return ((-center.y).atan2(-center.x), 0.3);   // the limb is off screen
    }
    let step = 2.0 * PI / n as f64;
    (best_start as f64 * step + (best_len - 1) as f64 * step / 2.0, best_len as f64 * step / 2.0)
}

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    // Zoom 1 puts the limb across the lower middle; smaller zooms back off to the whole disk.
    // In portrait the disk stays centered with its top at the subject height.
    let radius = 1.7 * c.star_zoom;
    let s = cam.screen_scale;
    let center = if cam.portrait {
        DVec2::new(0.0, cam.subject_y * s - radius)
    } else {
        DVec2::new(c.star_center_x * cam.aspect, c.star_limb_y - radius)
    };
    // Swift's truncatingRemainder keeps the sign of the dividend, like Rust's %
    let rotation = (t * 0.004 * c.star_rotation) % (2.0 * PI);
    let col = c.close_star.color();
    // even "quiet" star types get a few spots in the close-up
    let activity = c.close_star.activity().max(0.35);
    p.a = [center.x as f32, center.y as f32, radius as f32, rotation as f32];
    p.b = [col.r, col.g, col.b, (c.star_spots * activity) as f32];
    let (arc_mid, arc_half) = visible_limb(center, radius, cam.aspect * s, s);
    p.g = [arc_mid as f32, arc_half as f32, 0.0, 0.0];
    let limb_angle = |rng: &mut Rng| arc_mid + arc_half * rng.range(-0.85, 0.85);
    // Eruptions and CMEs reach several radii out, so of a few candidate angles they take the
    // one with the most screen left beyond the limb (sideways, when the whole disk shows).
    let (half_w, half_h) = (cam.aspect * s, s);
    let roomy_angle = |rng: &mut Rng| {
        let mut best = limb_angle(rng);
        let mut best_room = f64::NEG_INFINITY;
        for i in 0..4 {
            let a = if i == 0 { best } else { limb_angle(rng) };
            let dir = DVec2::new(a.cos(), a.sin());
            let pt = center + radius * dir;
            let tx = if dir.x == 0.0 { f64::INFINITY } else { ((if dir.x > 0.0 { half_w } else { -half_w }) - pt.x) / dir.x };
            let ty = if dir.y == 0.0 { f64::INFINITY } else { ((if dir.y > 0.0 { half_h } else { -half_h }) - pt.y) / dir.y };
            let room = tx.min(ty);
            if room > best_room {
                best = a;
                best_room = room;
            }
        }
        best
    };

    // Slots: see the star close-up section of stars.wgsl. Progress is age / duration.
    let rate = c.star_flares.rate();
    if let Some((age, mut rng)) = events.active(events::STELLAR_FLARE, rate, t, demo) {
        let ang = limb_angle(&mut rng);
        let depth = rng.range(0.0, 0.015);   // just inside the limb, so its loop arcade stands clear of it
        let bright = smoothstep(0.0, 1.5, age) * (-age / 12.0).exp();
        p.c = [ang as f32, depth as f32, (bright * 3.0) as f32, rng.range(0.05, 0.08) as f32];
        p.f[0] = (age / events::STELLAR_FLARE.duration) as f32;
    }
    if let Some((age, mut rng)) = events.active(events::SURGE, rate, t, demo) {
        let f = age / events::SURGE.duration;
        p.f[1] = limb_angle(&mut rng) as f32;
        p.f[2] = f as f32;
        p.f[3] = (smoothstep(0.0, 0.04, f) * (1.0 - smoothstep(0.85, 1.0, f))) as f32;
    }
    if let Some((age, mut rng)) = events.active(events::CORONAL_EJECTION, rate, t, demo) {
        let f = age / events::CORONAL_EJECTION.duration;
        let ang = roomy_angle(&mut rng);
        p.d = [ang as f32, f as f32, (smoothstep(0.0, 0.04, f) * (1.0 - smoothstep(0.7, 1.0, f))) as f32, rng.range(0.0, 50.0) as f32];
    }
    if let Some((age, mut rng)) = events.active(events::PROMINENCE_ERUPTION, rate, t, demo) {
        let f = age / events::PROMINENCE_ERUPTION.duration;
        let ang = roomy_angle(&mut rng);
        p.e = [ang as f32, f as f32, (smoothstep(0.0, 0.06, f) * (1.0 - smoothstep(0.85, 1.0, f))) as f32, rng.range(0.0, 50.0) as f32];
    }
    p
}
