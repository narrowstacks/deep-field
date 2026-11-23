//! Black hole merger (MARK: Black hole merger in Scenes/SceneParams.swift), plus the published
//! detections the Customize window offers as presets (BlackHoleDetection in Config/Options.swift).

use std::f64::consts::PI;

use glam::DVec3;

use crate::camera::Camera;
use crate::config::{BlackHoleMergerModel, WallpaperConfig};
use crate::events::{DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::{normalize, smoothstep, v3w, v4w};
use crate::palette::level;
use crate::scene_params::{bbh_clock, bbh_speed};
use crate::scenes::neutron_merger::{kepler, merger_mean_anomaly, merger_orbit, merger_periapsis, Inspiral};

/// BlackHoleMergerModel.shaderIndex: what surrounds the pair in the shader (0 empty space,
/// 1 a star cluster, 2 a supermassive pair's gas disk, 3 a quasar's disk).
pub fn model_shader_index(m: BlackHoleMergerModel) -> f32 {
    match m {
        BlackHoleMergerModel::Stellar => 0.0,
        BlackHoleMergerModel::Intermediate => 1.0,
        BlackHoleMergerModel::Supermassive => 2.0,
        BlackHoleMergerModel::AgnDisk => 3.0,
    }
}

/// BlackHoleMergerModel.title.
#[allow(dead_code)]
pub fn model_title(m: BlackHoleMergerModel) -> &'static str {
    match m {
        BlackHoleMergerModel::Stellar => "Stellar",
        BlackHoleMergerModel::AgnDisk => "Stellar, in a quasar's disk",
        BlackHoleMergerModel::Intermediate => "Intermediate, in a cluster",
        BlackHoleMergerModel::Supermassive => "Supermassive, with a gas disk",
    }
}

/// A binary black hole merger heard by LIGO, Virgo and KAGRA, as published (median values,
/// rounded). Applying one sets the black hole merger's mass ratio, remnant spin, precession,
/// viewing angle and size class.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug)]
pub struct BlackHoleDetection {
    pub name: &'static str,
    /// solar masses
    pub m1: f64,
    pub m2: f64,
    pub remnant: f64,
    /// the remnant's dimensionless spin
    pub spin: f64,
    /// 0 for spins along the orbit's axis, 1 for strongly tilted ones
    pub precession: f64,
    /// angle between the orbit's axis and our line of sight, degrees
    pub view: f64,
    pub model: BlackHoleMergerModel,
    pub eccentric: bool,
    pub note: &'static str,
}

#[allow(dead_code)]
impl BlackHoleDetection {
    pub fn ratio(&self) -> f64 {
        ((self.m2 / self.m1) * 100.0).round() / 100.0
    }

    pub fn matches(&self, c: &WallpaperConfig) -> bool {
        c.bbh_mass_ratio == self.ratio() && c.bbh_spin == self.spin && c.bbh_precession == self.precession
            && c.bbh_view == self.view && c.bbh_model == self.model && c.bbh_eccentric == self.eccentric
    }

    pub fn apply(&self, c: &mut WallpaperConfig) {
        c.bbh_mass_ratio = self.ratio();
        c.bbh_spin = self.spin;
        c.bbh_precession = self.precession;
        c.bbh_view = self.view;
        c.bbh_model = self.model;
        c.bbh_eccentric = self.eccentric;
    }
}

const fn det(name: &'static str, m1: f64, m2: f64, remnant: f64, spin: f64, precession: f64, view: f64,
             model: BlackHoleMergerModel, eccentric: bool, note: &'static str) -> BlackHoleDetection {
    BlackHoleDetection { name, m1, m2, remnant, spin, precession, view, model, eccentric, note }
}

#[allow(dead_code)]
pub const DETECTIONS: &[BlackHoleDetection] = {
    use BlackHoleMergerModel::*;
    &[
        det("GW150914", 36.0, 31.0, 63.0, 0.69, 0.15, 30.0, Stellar, false,
            "The first gravitational waves ever detected, on 14 September 2015."),
        det("GW170814", 31.0, 25.0, 53.0, 0.72, 0.2, 50.0, Stellar, false,
            "The first heard by three detectors, which pinned down the waves' polarization."),
        det("GW190412", 30.0, 8.0, 37.0, 0.67, 0.3, 45.0, Stellar, false,
            "The first clearly unequal pair. Its waves carry a higher harmonic, a third arm in the ripples."),
        det("GW190521", 85.0, 66.0, 142.0, 0.72, 0.7, 50.0, AgnDisk, true,
            "The first intermediate-mass black hole, from holes too heavy for single stars. It may have merged on an eccentric orbit inside a quasar's disk, where a flare was seen a month later."),
        det("GW190814", 23.0, 2.6, 26.0, 0.28, 0.05, 45.0, Stellar, false,
            "A 9 to 1 pair. The light partner is the lightest black hole or the heaviest neutron star known."),
        det("GW231123", 137.0, 103.0, 225.0, 0.85, 0.8, 40.0, Intermediate, false,
            "The most massive merger yet, of two black holes spinning close to the limit."),
        det("GW250114", 34.0, 32.0, 63.0, 0.68, 0.1, 30.0, Stellar, false,
            "The clearest signal yet. Its ringdown confirmed Hawking's area theorem."),
    ]
};

/// The pair's chirp for mass ratio q, with the heavier hole's mass M setting the scale. With
/// eta the symmetric mass ratio, the phase left before the merger goes as eta^(-3/8) tau^(5/8)
/// and the separation as M (eta tau)^(1/4), so an unequal pair is tighter and winds through
/// more orbits in the same time.
fn bbh_inspiral(q: f64, m: f64, eccentric: bool) -> Inspiral {
    let eta4 = 4.0 * q / ((1.0 + q) * (1.0 + q));
    Inspiral {
        k: 4.5 * eta4.powf(-0.375),
        a: 2.6 * eta4.powf(0.25) * m,
        cap_a: 24.0,
        cap_e: 0.8,
        ecc_end: if eccentric { 0.55 } else { 0.0 },
    }
}

/// The remnant of holes of mass m1 and m2: their sum less the energy the waves carried off,
/// about 5% for an equal pair and less for unequal ones.
fn bbh_remnant(m1: f64, m2: f64) -> f64 {
    let eta4 = 4.0 * m1 * m2 / ((m1 + m2) * (m1 + m2));
    (m1 + m2) * (1.0 - 0.048 * eta4 * eta4)
}

/// Generations in a hierarchical chain: each remnant becomes the heavy partner of the next
/// merger, three times over, before the scene starts afresh.
const BBH_GENERATIONS: i32 = 3;

/// How far the recoil kick throws the remnant, in scene units. Unequal masses beam the waves
/// unevenly (Gonzalez et al. 2007: at most about 175 km/s, near a 1 to 3 pair); spins tilted
/// into the orbital plane, which also drive precession, can add thousands of km/s.
fn bbh_kick(c: &WallpaperConfig, q: f64) -> f64 {
    let eta = q / ((1.0 + q) * (1.0 + q));
    let vm = 12000.0 * eta * eta * (1.0 - 4.0 * eta).max(0.0).sqrt() * (1.0 - 0.93 * eta);
    let v = vm / 175.0 + 1.5 * c.bbh_precession.max(0.0).min(1.0);
    (c.bbh_kick.max(0.0) * v * 1.8).min(7.0)
}

#[allow(clippy::too_many_arguments)]
pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, _width: u32, _height: u32,
             _events: &EventSchedule, demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let k = bbh_clock(c, t, demo);
    let u = k.u;
    let tau = k.tau();
    let q0 = c.bbh_mass_ratio.max(0.05).min(1.0);
    let model = c.bbh_model;

    // In a chain the waiting hole is the last remnant, so each new companion is relatively
    // lighter. Masses are in units of the first heavy hole.
    let gen = |index: f64| -> i32 {
        if !c.bbh_chain {
            return 0;
        }
        let n = BBH_GENERATIONS as f64;
        (index - n * (index / n).floor()) as i32
    };
    let heavy = |g: i32| -> f64 { (0..g).fold(1.0, |m, _| bbh_remnant(m, q0)) };
    let gn = gen(k.index);
    let mass = heavy(gn);
    let m_prev = heavy(gen(k.index - 1.0));
    let peak = bbh_remnant(m_prev, q0);
    let q = q0 / mass;
    let s = bbh_inspiral(q, mass, c.bbh_eccentric);
    let kk = s.k;
    let eta4 = 4.0 * q / ((1.0 + q) * (1.0 + q));

    // The total angular momentum J leans away from our line of sight by the viewing angle.
    // Spins tilted off it make the orbit precess around J, faster as the orbit tightens: the
    // precession rate goes as the orbital frequency to the 5/3, so its phase as tau^(3/8).
    let view = c.bbh_view / 180.0 * PI;
    let to_cam = normalize(cam.pos);
    let lean = normalize(0.25f64.cos() * cam.up + 0.25f64.sin() * cam.right);
    let jv = normalize(view.cos() * to_cam + view.sin() * lean);
    let ja = normalize(jv.cross(cam.right));
    let jb = jv.cross(ja);
    let beta = 0.5 * c.bbh_precession.max(0.0).min(1.0);
    // (eased over the last moments, where the rate would otherwise run away and the plane
    // would lurch between frames)
    let normal = |tau: f64, index: f64| -> DVec3 {
        let ph = index * 2.4 - 2.2 * ((tau.max(0.0) + 0.3).powf(0.375) - 0.3f64.powf(0.375));
        normalize(beta.cos() * jv + beta.sin() * (ph.cos() * ja + ph.sin() * jb))
    };
    let inspiralling = tau < k.tau_a();
    // the plane of the coming pair's orbit, or, until the companion arrives, of the last one's
    let n = if inspiralling { normal(tau, k.index) } else { normal(0.0, k.index - 1.0) };
    let e1 = normalize(cam.right - n * cam.right.dot(n));
    let e2 = n.cross(e1);
    let m_c = merger_mean_anomaly(k.tau_c(), &k, &s) + kk * k.tau_c().powf(0.625);
    let phi0_next = m_c + merger_periapsis(k.index);
    let phi0_last = m_c + merger_periapsis(k.index - 1.0);
    // An eccentric orbit's periapsis advances each turn, more as it tightens (relativistic
    // apsidal precession), so the path traces a rosette: zoom out, whirl round, zoom out.
    let rosette = if c.bbh_eccentric { 0.3 } else { 0.0 };

    // The recoil kick: the remnant flies off from where the pair merged and coasts to a
    // stop (slowed for looks), where the next companion finds it. The stops lie on a small
    // circle round the frame's center, a golden angle apart, so it never wanders off.
    let kick = bbh_kick(c, q);
    let stop = |i: f64| -> DVec3 { ((2.4 * i).cos() * cam.right + (2.4 * i).sin() * cam.up) * (kick / 1.864) };
    let coast = ((1.0 - (-u / 10.0).exp()) / (1.0 - (-6.0f64).exp())).min(1.0);
    let from = stop(k.index - 1.0);
    let to = stop(k.index);
    let center = from + (to - from) * coast;
    let velocity = (to - from) * if u < 60.0 { (-u / 10.0).exp() / (10.0 * (1.0 - (-6.0f64).exp())) } else { 0.0 };

    // The companion, as in the neutron star merger: captured on a wide eccentric orbit and
    // worn down into the chirp.
    let r0 = 0.6;
    // The shadows meet before the holes do: the chirp's separation falls to zero at the
    // merger, but what we see joins at contact, a little inside the two shadows' radii. The
    // separation eases onto that contact distance instead of sliding to a point.
    let contact = 0.8 * r0 * (mass + q0);
    let mut rel = DVec3::ZERO;
    let mut presence = 0.0;
    let mut a = 0.0;
    let mut gas_angle = 0.0; // the binary's direction in the orbital plane, for the gas's streams
    if inspiralling {
        let (aa, e) = merger_orbit(tau, &k, &s);
        a = aa;
        let m = merger_mean_anomaly(tau, &k, &s);
        let ea = kepler(m, e);
        let r = aa * (1.0 - e * ea.cos());
        let nu = 2.0 * ((1.0 + e).sqrt() * (ea / 2.0).sin()).atan2((1.0 - e).sqrt() * (ea / 2.0).cos());
        let w = smoothstep(k.tau_c(), k.tau_a(), tau);
        let ang = nu + merger_periapsis(k.index) + rosette * (m - m_c) * (1.0 - w);
        rel = (ang.cos() * e1 + ang.sin() * e2) * (r.powf(4.0) + contact.powf(4.0)).powf(0.25);
        // The gas follows the orbit's mean motion until a second before the merger, then
        // can't keep up (it decouples) and turns on at that rate.
        gas_angle = if tau >= 1.0 { m + merger_periapsis(k.index) } else { phi0_next - kk + 0.625 * kk * (1.0 - tau) };
        presence = smoothstep(k.tau_a(), k.tau_a() - 4.0, tau);
    }
    // the heavier hole moves less: each sits opposite the other about their center of mass
    let share = q / (1.0 + q) * (1.0 - smoothstep(k.tau_c(), k.tau_a(), tau));
    let mut c_a = center - rel * share;
    let mut c_b = center + rel * (1.0 - share);

    // Shadow sizes go with mass. The remnant swells at the merger; outside a chain (and when
    // a chain starts over) the frame then eases back out until it is the size of the next
    // pair's heavier hole.
    let settle = if gn == 0 { smoothstep(0.12 * k.cycle, 0.34 * k.cycle, u) } else { 0.0 };
    let g = (m_prev + (peak - m_prev) * smoothstep(0.0, 0.8, u)) * (1.0 - settle) + mass * settle;
    let lens = 2.4 * c.bbh_lensing.max(0.0);
    // The remnant bends light with the pair's whole mass from the start (less what the
    // waves carry off during the ringdown), so the lensed sky doesn't jump at the merger.
    let lens_mass = (m_prev + q0 + (peak - m_prev - q0) * smoothstep(0.0, 0.8, u)) * (1.0 - settle) + mass * settle;
    // the photon rings brighten through the merger, rising before it and fading after
    let ring_boost = if u < k.cycle / 2.0 {
        1.0 + 1.2 * (-u / 1.5).exp()
    } else {
        1.0 + 1.2 * (-(tau / 0.6) * (tau / 0.6)).exp()
    };

    // Ringdown: the remnant's fundamental quasinormal mode, a little above the pitch the
    // chirp ends on. Faster spin rings higher and for longer (fits from Berti, Cardoso and
    // Will 2006, relative to a 0.69 spin). Remnants deep in a chain spin a little faster.
    let chi = (c.bbh_spin.max(0.0) + 0.05 * gen(k.index - 1.0) as f64).min(0.98);
    let qnm_f = 1.0 - 0.63 * (1.0 - chi).powf(0.3);
    let qnm_q = 2.0 * (1.0 - chi).powf(-0.45);
    let ring_omega = 4.65 * kk * 1.2 * qnm_f / 0.557; // 4.65 K: the chirp's last wave frequency

    // A supermassive pair clears a cavity about twice its orbit in the gas disk. Late in the
    // chirp the orbit shrinks faster than the gas can follow (decoupling), so the cavity
    // stays wide through the merger and then slowly refills, feeding the remnant.
    let a_dec = s.a * (0.1 * k.tau_c()).powf(0.25);
    let cavity = if inspiralling {
        let open = smoothstep(k.tau_a(), k.tau_a() - 40.0, tau);
        1.1 + 1.5 * a.max(a_dec).min(3.5) * open
    } else {
        1.1 + 1.5 * a_dec.min(3.5) * (1.0 - smoothstep(0.0, 0.25 * k.cycle, u))
    };
    let glow = if model == BlackHoleMergerModel::AgnDisk {
        // In a quasar's disk the kicked remnant plows through dense gas and lights it up
        // some time later (the flare candidate for GW190521 came about a month after).
        smoothstep(6.0, 16.0, u) * (-(u - 16.0).max(0.0) / 30.0).exp() * (0.5 + 0.25 * kick)
    } else {
        smoothstep(0.05 * k.cycle, 0.2 * k.cycle, u) * (1.0 - smoothstep(0.3 * k.cycle, 0.6 * k.cycle, u))
    };
    // The remnant's jets point along its spin, which the merger can flip: the old jets fade
    // while the new ones grow, as in X-shaped radio galaxies.
    let jets = if model == BlackHoleMergerModel::Supermassive { 1.0 } else { 0.0 };
    let jet_new = jets * smoothstep(3.0, 25.0, u);
    let jet_old = jets * (1.0 - smoothstep(0.0, 0.5 * k.cycle, u));
    // A quasar's disk is far wider than the frame and lies at its own tilt; the others are
    // in the plane of the binary's total angular momentum.
    let disk_normal = if model == BlackHoleMergerModel::AgnDisk {
        normalize(0.9f64.cos() * to_cam + 0.9f64.sin() * cam.up)
    } else {
        jv
    };

    // After the merger the pair's two lobes don't vanish at once: they keep turning at the
    // ringdown's pattern speed (half its wave frequency) while they slide together and the
    // light partner's lobe is absorbed, fading over the damping time. That is the spinning
    // peanut, and the shadow and the lensing carry straight on from the moment before.
    let mut radius_b = if inspiralling { r0 * q0 } else { 0.0 };
    let mut lens_b = lens * q0.sqrt() * presence;
    let mut lens_a = lens * lens_mass.sqrt();
    let mut lobes = 1.0; // how far the tidal stretch still shows: 1 for the pair, fading after
    if !inspiralling {
        // and after it the streams' turn winds down over about a second
        gas_angle = phi0_last - kk + 0.625 * kk * (1.0 + (1.0 - (-u).exp()));
        let f = (-u / (2.0 * qnm_q / ring_omega)).exp();
        if f > 0.003 {
            let q_prev = q0 / m_prev;
            let share_prev = q_prev / (1.0 + q_prev);
            let reach = 0.8 * r0 * (m_prev + q0) * f;
            let psi = phi0_last + 0.5 * ring_omega * u;
            let dir = psi.cos() * e1 + psi.sin() * e2;
            c_a = center - dir * reach * share_prev;
            c_b = center + dir * reach * (1.0 - share_prev);
            radius_b = r0 * q0 * f.sqrt();
            let w_b = q0 / (m_prev + q0) * f;
            lens_a = lens * (lens_mass * (1.0 - w_b)).sqrt();
            lens_b = lens * (lens_mass * w_b).sqrt();
            lobes = f;
        }
    }

    // (decided by the cycle's half, not tauW's sign: at the merger instant tauW is -0)
    let after_merger = u < k.cycle / 2.0;
    let tau_w = if after_merger { -u } else { tau };
    let phi0 = (if after_merger { phi0_last } else { phi0_next }) % (2.0 * PI);
    let peri = (if after_merger { merger_periapsis(k.index - 1.0) } else { merger_periapsis(k.index) }) % (2.0 * PI);
    p.a = v4w(c_a, (r0 * g) as f32);
    p.b = v4w(c_b, radius_b as f32);
    p.c = v4w(n, (c.bbh_waves * eta4.powf(0.5)) as f32);
    p.d = v4w(e1, tau_w as f32);
    // the gas's streams and second mini-disk outlast the companion by a few seconds
    let gas_pair = if inspiralling { presence } else { (-u / 4.0).exp() };
    p.e = v3w(c.bbh_ring_color.light3(level::BBH_RING), gas_pair as f32);
    p.f = v3w(c.bbh_hot.light3(level::BBH_GAS), u as f32);
    p.g = v3w(c.bbh_cool.light3(level::BBH_GAS), model_shader_index(model));
    p.h = [kk as f32, phi0 as f32, k.tau_c() as f32, ((1.0 - q) / (1.0 + q)) as f32];
    p.i = [lens_a as f32, lens_b as f32, chi as f32, ring_boost as f32];
    p.j = [ring_omega as f32, (2.0 * qnm_q / ring_omega) as f32, cavity as f32, glow as f32];
    p.k = v4w(normal(0.0, k.index - 1.0), jet_new as f32);
    p.l = v4w(normal(0.0, k.index - 2.0), jet_old as f32);
    p.m = v4w(disk_normal, (gas_angle % (2.0 * PI)) as f32);
    p.n = [peri as f32, s.ecc_end as f32, rosette as f32, lobes as f32];
    let flags = (if c.bbh_trace { 1.0 } else { 0.0 }) + (if c.bbh_galaxy { 2.0 } else { 0.0 });
    p.o = v4w(center, flags);
    // the scene's own clock, for the motions the shader runs on its own (gas, cluster, jets)
    p.p = v4w(velocity, ((t * bbh_speed(c)) % 100_000.0) as f32);
    p
}
