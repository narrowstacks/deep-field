//! Aurora from Orbit's SceneParams (Scenes/SceneParams.swift, MARK: Aurora from orbit).

use std::f64::consts::PI;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{self, DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{smoothstep, v3w};
use crate::palette::level;

/// Swift's `remainder(dividingBy:)`: the IEEE remainder, x less the nearest multiple of y.
fn ieee_remainder(x: f64, y: f64) -> f64 {
    x - (x / y).round_ties_even() * y
}

#[allow(unused_variables)]
pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, width: u32, height: u32,
             events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let h = c.aurora_altitude / 6371.0;
    // pitch down so the limb's top sits at `auroraHorizon` on screen: it lies `dip` below
    // the horizontal, and the screen height v is atan(v * tanHalf) from the view's center
    let dip = (1.0 / (1.0 + h)).acos();
    let pitch = -dip - (c.aurora_horizon * cam.tan_half).atan();
    let deg = PI / 180.0;
    let (mut sub, mut storm) = (0.0, 0.0);
    if let Some((age, _)) = events.active(events::SUBSTORM, c.aurora_events.rate(), t, demo) {
        let f = age / events::SUBSTORM.duration;
        sub = substorm(f);
        storm = storm_lead(f, c.aurora_activity);
    }
    p.a = [pitch as f32, h as f32, (c.aurora_distance * deg) as f32, (c.aurora_oval_size * deg) as f32];
    p.b = v3w(c.aurora_green.light3(level::AURORA), c.aurora_brightness as f32);
    p.c = v3w(c.aurora_red.light3(level::AURORA), c.aurora_activity as f32);
    p.d = v3w(c.aurora_fringe.light3(level::AURORA), sub as f32);
    p.e = v3w(c.aurora_city_color.light3(level::AURORA_CITY), c.aurora_city_lights as f32);
    // Earth turns eastward under the view, about four times its real rate by default, so a
    // full turn takes under six hours. The view starts over Europe and heads west from there.
    let spin = 0.0003 * c.aurora_drift;
    let lon = ieee_remainder(10.0 * deg - spin * t, 2.0 * PI);
    p.f = [c.aurora_clouds as f32, c.aurora_moonlight as f32, spin as f32, c.aurora_lightning.rate() as f32];
    // z: whether the real Earth maps are bound (the renderer sets it), w: the view's longitude
    p.g = [c.aurora_sunrise as f32, 5.3, 0.0, lon as f32];
    p.h = [storm as f32, 0.0, 0.0, 0.0];
    p
}

/// A substorm's strength through the event (f from 0 to 1): a quick onset, a long fade.
fn substorm(f: f64) -> f64 {
    smoothstep(0.0, 0.08, f) * (1.0 - smoothstep(0.45, 1.0, f))
}

const STORM_STEPS: usize = 256;

fn storm_total() -> f64 {
    (0..STORM_STEPS).map(|k| substorm((k as f64 + 0.5) / STORM_STEPS as f64)).fold(0.0, |a, b| a + b)
}

/// How far a substorm has pushed the aurora's folds ahead by `f` through the event, in
/// seconds of their clock: the running total of its strength. A whole storm adds a whole
/// number of turns of both fold waves (0.3 and 0.6 rad per second, so 2 pi / 0.3 each), so
/// they're back in step when it ends instead of jumping. The number of turns follows the
/// aurora's speed, which makes the folds run about 1.8 times their calm pace at the storm's
/// height at any speed (and not at all below about 0.08, where a turn would be too much).
fn storm_lead(f: f64, activity: f64) -> f64 {
    let x = f.max(0.0).min(1.0) * STORM_STEPS as f64;
    let whole = x as usize;
    let mut sum = (0..whole).map(|k| substorm((k as f64 + 0.5) / STORM_STEPS as f64)).fold(0.0, |a, b| a + b);
    if whole < STORM_STEPS {
        sum += (x - whole as f64) * substorm((whole as f64 + 0.5) / STORM_STEPS as f64);
    }
    // Swift's rounded() rounds half away from zero, like Rust's round()
    let turns = (activity * 6.0).round();
    turns * (2.0 * PI / 0.3) * sum / storm_total()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn storm_lead_is_whole_turns_at_the_end() {
        let lead = storm_lead(1.0, 0.6);
        let turn = 2.0 * PI / 0.3;
        assert!((lead / turn - 4.0).abs() < 1e-9);
        assert_eq!(storm_lead(0.0, 0.6), 0.0);
    }

    #[test]
    fn view_longitude_wraps_to_plus_minus_pi() {
        assert!((ieee_remainder(3.5 * PI, 2.0 * PI) + 0.5 * PI).abs() < 1e-12);
        assert!((ieee_remainder(0.1, 2.0 * PI) - 0.1).abs() < 1e-15);
    }
}
