//! Neutron star merger (MARK: Neutron star merger in Scenes/SceneParams.swift). The inspiral
//! helpers here are shared with the black hole merger.

use std::f64::consts::PI;

use glam::DVec3;

use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::events::{DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, smoothstep, v3w, v4w};
use crate::palette::level;
use crate::scene_params::{merger_clock, MergerClock};

/// A captured companion's inspiral: the chirp's constant K (orbital phase phi0 - K tau^(5/8)
/// once the orbit is circular), its separation A tau^(1/4), and the captured orbit's
/// semi-major axis (its apoapsis lies beyond the frame) and eccentricity.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Inspiral {
    pub k: f64,
    pub a: f64,
    pub cap_a: f64,
    pub cap_e: f64,
    /// Eccentricity kept through the chirp (0 rounds the orbit out), shed only at the end.
    pub ecc_end: f64,
}

const NEUTRON_INSPIRAL: Inspiral = Inspiral { k: 4.5, a: 1.55, cap_a: 14.5, cap_e: 0.8, ecc_end: 0.0 };

/// The companion's orbit relative to the remnant at time-to-merger tau: semi-major axis and
/// eccentricity. Gravitational waves shrink and circularize it; by tauC it has joined the
/// circular chirp, whose separation goes as tau^(1/4).
pub(crate) fn merger_orbit(tau: f64, k: &MergerClock, s: &Inspiral) -> (f64, f64) {
    let w = smoothstep(k.tau_c(), k.tau_a(), tau);
    let chirp = s.a * tau.max(0.0).powf(0.25);
    (chirp + (s.cap_a - chirp) * w, s.cap_e * w + (1.0 - w) * s.ecc_end * smoothstep(0.3, 4.0, tau))
}

/// Mean anomaly at tau: pi (apoapsis) at tauA, then advanced at the Kepler rate for the
/// shrinking orbit (omega^2 a^3 fixed, matching the chirp), in closed form once it's circular.
pub(crate) fn merger_mean_anomaly(tau: f64, k: &MergerClock, s: &Inspiral) -> f64 {
    let rate = |x: f64| 0.625 * s.k * (merger_orbit(x, k, s).0 / s.a).powf(-1.5);
    let lo = tau.max(k.tau_c());
    let hi = k.tau_a();
    let mut m = PI;
    if hi > lo {
        // Simpson's rule
        let steps = 160;
        let h = (hi - lo) / steps as f64;
        let mut sum = rate(lo) + rate(hi);
        for i in 1..steps {
            sum += rate(lo + i as f64 * h) * if i % 2 == 1 { 4.0 } else { 2.0 };
        }
        m += sum * h / 3.0;
    }
    if tau < k.tau_c() {
        m += s.k * (k.tau_c().powf(0.625) - tau.max(0.0).powf(0.625));
    }
    m
}

/// Where the periapsis points in cycle `index`: companions come in from alternate sides.
pub(crate) fn merger_periapsis(index: f64) -> f64 {
    // Swift's truncatingRemainder keeps the dividend's sign, like Rust's %
    (if index % 2.0 == 0.0 { 0.0 } else { PI }) + 0.35 * (index * 1.7).sin()
}

/// Kepler's equation for eccentric anomaly E (Newton steps from m + e sin m).
pub(crate) fn kepler(m: f64, e: f64) -> f64 {
    let mut ea = m + e * m.sin();
    for _ in 0..12 {
        ea -= (ea - e * ea.sin() - m) / (1.0 - e * ea.cos());
    }
    ea
}

#[allow(clippy::too_many_arguments)]
pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             _events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let k = merger_clock(c, t, demo);
    let u = k.u;
    let tau = k.tau();
    // the orbit axis leans away from our line of sight, up and a little to the side
    let view = c.merger_view / 180.0 * PI;
    let to_cam = normalize(cam.pos);
    let lean = normalize(0.25f64.cos() * cam.up + 0.25f64.sin() * cam.right);
    let n = normalize(view.cos() * to_cam + view.sin() * lean);
    let e1 = normalize(cam.right - n * cam.right.dot(n));
    let e2 = n.cross(e1);
    let s = NEUTRON_INSPIRAL;
    let kk = s.k;
    // the circular chirp's phase constant for this cycle's pair, and for the last one
    let m_c = merger_mean_anomaly(k.tau_c(), &k, &s) + kk * k.tau_c().powf(0.625);
    let phi0_next = m_c + merger_periapsis(k.index);
    let phi0_last = m_c + merger_periapsis(k.index - 1.0);

    // The companion: falls in from apoapsis beyond the frame at tauA, swings close past the
    // remnant, and is worn down into the chirp. Its position comes from Kepler's equation.
    let mut rel = DVec3::ZERO;
    let mut presence = 0.0;
    let mut stretch = 1.0;
    if tau < k.tau_a() {
        let (a, e) = merger_orbit(tau, &k, &s);
        let m = merger_mean_anomaly(tau, &k, &s);
        let ea = kepler(m, e);
        let r = a * (1.0 - e * ea.cos());
        let nu = 2.0 * ((1.0 + e).sqrt() * (ea / 2.0).sin()).atan2((1.0 - e).sqrt() * (ea / 2.0).cos());
        let ang = nu + merger_periapsis(k.index);
        rel = (ang.cos() * e1 + ang.sin() * e2) * r;
        presence = smoothstep(k.tau_a(), k.tau_a() - 4.0, tau);
        // tides stretch each star toward the other in the last moments
        stretch = 1.0 + 0.9 * (2.6 * 0.2 / r.max(1e-3)).min(1.0).powf(3.0);
    }
    // The pair's balance point: the remnant stays put while the companion is far and
    // light on it, and the two share the orbit equally as it tightens (equal masses).
    let share = 0.5 * (1.0 - smoothstep(k.tau_c(), k.tau_a(), tau));
    let c_a = -rel * share;
    let c_b = rel * (1.0 - share);

    // each star's magnetic axis turns with its spin
    let magnetic = |incl: f64, period: f64, offset: f64| -> DVec3 {
        let w = 2.0 * PI * t / period + offset;
        incl.cos() * n + incl.sin() * (w.cos() * e1 + w.sin() * e2)
    };
    // The remnant is a magnetar: a slow beat in its glow and field, and a spin-down
    // brightening just after it forms. The beat quiets once it has a partner.
    let beat = (0.5 + 0.5 * (2.0 * PI * t / 5.0).sin()).powf(3.0);
    let rem_glow = 1.0 + 0.6 * beat * (1.0 - 0.6 * presence) + 1.2 * (-u / 25.0).exp();
    // the kilonova: bright, then a lingering nebula that dims as the next merger nears
    let kfade = (1.0 - 0.7 * smoothstep(k.post() * 0.5, k.post(), u))
        * (1.0 - 0.4 * smoothstep(0.8 * k.cycle, k.cycle, u));
    let flash = (-u / 0.3).exp();
    // waves: those still to arrive from the coming merger, or those spreading from the last
    let tau_w = if u < k.cycle / 2.0 { -u } else { tau };
    let phi0 = (if tau_w < 0.0 { phi0_last } else { phi0_next }) % (2.0 * PI);
    let star = c.merger_star_color.light3(level::MERGER_STAR);
    let b = c.merger_brightness as f32;
    p.a = v4w(c_a, rem_glow as f32);
    p.b = v4w(c_b, stretch as f32);
    p.c = v4w(n, c.merger_waves as f32);
    p.d = v4w(e1, tau_w as f32);
    p.e = v3w([star[0] * b, star[1] * b, star[2] * b], presence as f32);
    p.f = v3w(c.merger_hot.light3(level::MERGER_KILONOVA), u as f32);
    p.g = v3w(c.merger_cool.light3(level::MERGER_KILONOVA), kfade as f32);
    p.h = v4w(magnetic(0.6, 1.7, 0.0), if c.merger_jet { 1.0 } else { 0.0 });
    p.i = v4w(magnetic(0.85, 2.6, 2.0), c.merger_glow as f32);
    p.j = [kk as f32, phi0 as f32, k.tau_c() as f32, flash as f32];
    p
}
