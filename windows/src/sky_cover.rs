//! Which of the sky a scene's own bodies leave open at one moment, for placing sky events where
//! they can be seen (Scenes/SkyCover.swift). It reads the same `SceneParamsGpu` the shader draws
//! the bodies from, so it follows their settings and motion. Scenes not in `SCENES` leave nearly
//! all the sky open.

use glam::{DVec2, DVec3};

use crate::camera::Camera;
use crate::config::{EclipseSkyBody, RingStyle, SceneKind, WallpaperConfig};
use crate::events::{DemoMap, EventSchedule, Kind, COMET, SUPERNOVA};
use crate::gpu_types::{SceneParamsGpu, V4};
use crate::math::{mix, normalize, smoothstep, Rng};
use crate::scene_params;

pub const SCENES: [SceneKind; 6] = [
    SceneKind::AuroraOrbit, SceneKind::GasGiant, SceneKind::RoguePlanet,
    SceneKind::RingedPlanet, SceneKind::Eclipse, SceneKind::StellarSurface,
];

pub fn covers(scene: SceneKind) -> bool {
    SCENES.contains(&scene)
}

/// Kept clear of a body's edge (its limb glow, and the few pixels a supernova spans), in half
/// screen heights.
const EDGE: f64 = 0.04;

fn xyz(v: V4) -> DVec3 {
    DVec3::new(v[0] as f64, v[1] as f64, v[2] as f64)
}

fn angle(a: DVec3, b: DVec3) -> f64 {
    a.dot(b).clamp(-1.0, 1.0).acos()
}

fn pitched(r: DVec3, a: f64) -> DVec3 {
    DVec3::new(r.x, r.y * a.cos() + r.z * a.sin(), -r.y * a.sin() + r.z * a.cos())
}

pub struct SkyCover {
    scene: SceneKind,
    cam: Camera,
    p: SceneParamsGpu,
    /// `EDGE` in radians
    margin: f64,
}

impl SkyCover {
    pub fn new(c: &WallpaperConfig, cam: &Camera, t: f64) -> Option<SkyCover> {
        if !covers(c.scene) {
            return None;
        }
        let quiet = EventSchedule::with_enabled(0, false);
        let p = scene_params::build(c, t, cam, 0, 0, &quiet, &DemoMap::new());
        Some(SkyCover { scene: c.scene, cam: *cam, p, margin: EDGE * cam.tan_half })
    }

    /// Whether the sky shows along world direction `d`.
    pub fn open(&self, d: DVec3) -> bool {
        let (p, cam) = (&self.p, &self.cam);
        let outside = |body: V4, d: DVec3| -> bool {
            if !(body[3] > 0.0) {
                return true;
            }
            let center = xyz(body);
            let far = center.length();
            angle(d, center / far) > (body[3] as f64 / far).min(1.0).asin() + self.margin
        };
        // most scenes have their own frame: the camera at the origin, looking down +z
        let l = DVec3::new(d.dot(cam.right), d.dot(cam.up), d.dot(cam.fwd));
        match self.scene {
            // its small moon passes in seconds
            SceneKind::GasGiant => outside(p.a, l),
            SceneKind::RoguePlanet => outside(p.a, l) && outside(p.g, l),
            SceneKind::RingedPlanet => {
                let planet = -cam.pos;
                outside([planet.x as f32, planet.y as f32, planet.z as f32, p.a[3]], d) && !self.behind_dense_ring(d)
            }
            SceneKind::AuroraOrbit => {
                // the ray clears the air, which dims the stars up to 1.03 Earth radii
                let rd = pitched(l, p.a[0] as f64);
                let ro = DVec3::new(0.0, 1.0 + p.a[1] as f64, 0.0);
                (ro - rd * ro.dot(rd)).length() > 1.02
            }
            SceneKind::StellarSurface => match self.screen(d) {
                Some(q) => q.distance(DVec2::new(p.a[0] as f64, p.a[1] as f64)) > p.a[2] as f64 + EDGE * cam.screen_scale,
                None => false,
            },
            SceneKind::Eclipse => self.eclipse_open(d),
            _ => true,
        }
    }

    /// The ringed planet's rings let light through, but at high density the classic style's
    /// middle ring (opacity 0.55 to 0.85 before density) is nearly opaque.
    fn behind_dense_ring(&self, d: DVec3) -> bool {
        let (p, cam) = (&self.p, &self.cam);
        if p.j[0] != RingStyle::Classic.shader_index() || !(p.j[2] > 1.3) {
            return false;
        }
        let n = xyz(p.a);
        let den = d.dot(n);
        let t = if den.abs() > 1e-4 { -cam.pos.dot(n) / den } else { -1.0 };
        let r = (cam.pos + d * t).length() / p.a[3] as f64;
        // the width setting, as in the shader
        let unstretched = 1.24 + (r - 1.24) / p.j[1] as f64;
        t > 0.0 && unstretched > 1.5 && unstretched < 1.98
    }

    fn eclipse_open(&self, d: DVec3) -> bool {
        let (p, cam) = (&self.p, &self.cam);
        let Some(q) = self.screen(d) else { return false };
        let th = p.i[0] as f64;
        let margin = EDGE * th * cam.screen_scale;
        let rd = pitched(normalize(DVec3::new(q.x * th, q.y * th, 1.0)), p.i[1] as f64);
        // the ground: the horizon's dip (8 degrees), under far rims up to 0.027 radians tall
        if p.e[3] > 0.5 && rd.y.asin() < -0.139 + 0.027 + margin {
            return false;
        }
        // the sun with its bright inner corona, and the occluder over it (off the sun it's daylight)
        if angle(rd, xyz(p.a)) < (1.6 * p.a[3] as f64).atan() + margin {
            return false;
        }
        if p.f[3] > 0.0 {
            let body = xyz(p.f);
            let tan_r = p.f[3] as f64;
            if angle(rd, body) < tan_r.atan() + margin {
                return false;
            }
            if p.l[2] == crate::scenes::eclipse::body_shader_index(EclipseSkyBody::RingedGiant) {
                // the ring plane, as in the shader
                let n = normalize(DVec3::new(0.6, 1.0, -0.1));
                let den = rd.dot(n);
                let t = if den.abs() > 1e-4 { body.dot(n) / den } else { -1.0 };
                let r = (rd * t).distance(body) / (tan_r / (1.0 + tan_r * tan_r).sqrt());
                if t > 0.0 && r > 1.25 && r < 2.45 {
                    return false;
                }
            }
        }
        // the air's extinction, worse low down, and the clouds' average cover (they drift); with
        // under a tenth of the light left an event is lost in the glow
        let density = p.k[3] as f64;
        if !(density > 0.0) {
            return true;
        }
        let y = rd.y.max(0.0);
        let airmass = 1.0 / (y + 0.065 * (-y * 10.0).exp() + 0.012);
        let haze = p.l[0] as f64;
        let beta = (0..3)
            .map(|i| {
                let air = p.k[i] as f64;
                air * (1.0 - 0.5 * haze.min(1.0)) + 0.6 * haze * (0.3 + 0.7 * (1.15 - air).max(0.0))
            })
            .fold(f64::INFINITY, f64::min);
        (-density * airmass * (0.2 + 0.3 * beta)).exp() * (1.0 - 0.6 * p.l[1] as f64) > 0.1
    }

    /// How dark the sky is, 0 to 1. Only the eclipse's drowns its stars, in daylight.
    pub fn darkness(&self) -> f64 {
        if self.scene == SceneKind::Eclipse { smoothstep(2.6, 4.5, -(self.p.j[3] as f64)) } else { 1.0 }
    }

    /// Where `d` shows on the screen, in half screen heights as the screen-space scenes count them.
    fn screen(&self, d: DVec3) -> Option<DVec2> {
        let cam = &self.cam;
        cam.project(d).map(|s| DVec2::new(s.x * cam.aspect, s.y) * cam.screen_scale)
    }
}

/// The open sky over an event's life: covers spread through it, since bodies move.
pub struct OpenSky {
    pub camera: Camera,
    covers: Vec<SkyCover>,
}

impl OpenSky {
    /// None if nothing in the scene covers the sky.
    pub fn new(c: &WallpaperConfig, cam: &Camera, start: f64, duration: f64) -> Option<OpenSky> {
        let covers: Vec<SkyCover> =
            (0..=4).filter_map(|i| SkyCover::new(c, cam, start + duration * i as f64 / 4.0)).collect();
        if covers.is_empty() { None } else { Some(OpenSky { camera: *cam, covers }) }
    }

    /// Open through the first half, while a supernova is bright.
    pub fn open(&self, d: DVec3) -> bool {
        self.covers.iter().take(3).all(|c| c.open(d))
    }

    /// How many of 11 steps of a comet's pass from `a` to `b` are in open sky; it needs 9.
    fn open_steps(&self, a: DVec3, b: DVec3, anywhere: bool) -> usize {
        (1..12)
            .filter(|&i| {
                let f = i as f64 / 12.0;
                let d = normalize(mix(a, b, f));
                self.covers[(f * 4.0).round() as usize].open(d) && (anywhere || self.on_screen(d))
            })
            .count()
    }

    fn on_screen(&self, d: DVec3) -> bool {
        self.camera.project(d).is_some_and(|p| p.x.abs() < 1.0 && p.y.abs() < 1.0)
    }

    pub fn open_path(&self, a: DVec3, b: DVec3) -> bool {
        self.open_steps(a, b, true) >= 9
    }

    /// Open spots on a grid over the screen, enough to find any patch worth using.
    pub fn spots(&self) -> Vec<DVec3> {
        (0..14)
            .flat_map(|j| (0..24).map(move |i| (i, j)))
            .map(|(i, j)| self.camera.ray(-0.96 + 1.92 * i as f64 / 23.0, -0.94 + 1.88 * j as f64 / 13.0))
            .filter(|&d| self.open(d))
            .collect()
    }

    /// The first of some random placements (a supernova's spot, or a comet's two ends) in open
    /// sky, so one that already was stays put. If a dozen miss, a spot off the grid (for a comet,
    /// with the farthest spot it can reach through open sky, or if that's too near to see it
    /// move, a short path across the patch, brightest in it and passing behind the body or off
    /// the screen); None if there's none.
    pub fn place(&self, first: Vec<DVec3>, rng: &mut Rng, mut next: impl FnMut(&mut Rng) -> Vec<DVec3>) -> Option<Vec<DVec3>> {
        let single = first.len() == 1;
        let mut dirs = first;
        for _ in 0..12 {
            let ok = if dirs.len() == 1 { self.open(dirs[0]) } else { self.open_path(dirs[0], dirs[1]) };
            if ok {
                return Some(dirs);
            }
            dirs = next(rng);
        }
        let spots = self.spots();
        if spots.is_empty() {
            return None;
        }
        let a = spots[((rng.next() * spots.len() as f64) as usize).min(spots.len() - 1)];
        if single {
            return Some(vec![a]);
        }
        // half screen heights
        let reach = 0.4;
        let cam = &self.camera;
        let Some(at) = cam.project(a) else { return Some(vec![a, a]) };
        let mut by_distance = spots.clone();
        // Swift's sort isn't stable either, but ties in a dot product of distinct grid rays don't
        // come up in practice
        by_distance.sort_by(|x, y| x.dot(a).partial_cmp(&y.dot(a)).unwrap_or(std::cmp::Ordering::Equal));
        if let Some(&b) = by_distance.iter().find(|&&s| self.open_path(a, s)) {
            if let Some(to) = cam.project(b) {
                if DVec2::new((to.x - at.x) * cam.aspect, to.y - at.y).length() >= reach {
                    return Some(vec![a, b]);
                }
            }
        }
        let paths = (0..12).map(|i| {
            let q = i as f64 * std::f64::consts::PI / 6.0;
            let step = DVec2::new(q.cos() / cam.aspect, q.sin()) * reach / 2.0;
            vec![cam.ray(at.x - step.x, at.y - step.y), cam.ray(at.x + step.x, at.y + step.y)]
        });
        // Swift's max(by:) keeps the first of equal maxima (Iterator::max_by_key keeps the last)
        let mut best: Option<(usize, Vec<DVec3>)> = None;
        for p in paths {
            let n = self.open_steps(p[0], p[1], false);
            if best.as_ref().map_or(true, |(m, _)| n > *m) {
                best = Some((n, p));
            }
        }
        best.map(|(_, p)| p)
    }
}

/// Why a supernova or comet starting at `t` couldn't be seen on a screen of any of these
/// aspects, or None if it could.
pub fn hidden_reason(k: Kind, c: &WallpaperConfig, aspects: &[f64], t: f64) -> Option<String> {
    if k.id != SUPERNOVA.id && k.id != COMET.id {
        return None;
    }
    let comet = k.id == COMET.id;
    let name = if comet { "comet" } else { "supernova" };
    let skies: Vec<OpenSky> =
        aspects.iter().filter_map(|&a| OpenSky::new(c, &Camera::new(c, a), t, k.duration)).collect();
    let camera = skies.first()?.camera;
    if skies.iter().all(|s| s.spots().is_empty()) {
        return Some(format!("No open sky for a {name} with these settings"));
    }
    // it should show soon after the click: a supernova in its flash, a comet early in its pass
    let mut ages = vec![3.0, 6.0, 10.0, 15.0, 20.0, 25.0];
    if comet {
        ages.extend([30.0, 40.0, 50.0, 60.0]);
    }
    // the flash shows through more glow
    let enough = if comet { 0.1 } else { 0.02 };
    let dark = ages.iter().any(|age| SkyCover::new(c, &camera, t + age).map_or(1.0, |s| s.darkness()) > enough);
    if dark { None } else { Some(format!("The sky is too bright for a {name} now")) }
}

#[cfg(test)]
mod tests {
    //! SkyCoverCheck.swift: sky events keep to the open sky, and Show Me's answer matches whether
    //! they're drawn.
    use super::*;
    use crate::config::EclipseMotion;

    /// `crossing`: too small a patch to stay in, so a comet must cross it rather than stand still.
    fn fails(scene: SceneKind, aspect: f64, hidden: bool, crossing: bool, edit: impl Fn(&mut WallpaperConfig)) -> Vec<String> {
        let mut c = WallpaperConfig::default();
        c.set_scene(scene);
        edit(&mut c);
        let cam = Camera::new(&c, aspect);
        let start = 200.0;
        let mut out = vec![];
        for k in [SUPERNOVA, COMET] {
            let what = format!("{scene:?}, event {}", k.id);
            if hidden_reason(k, &c, &[aspect], start).is_some() != hidden {
                out.push(format!("{what}: Show Me has it {}", if hidden { "showing" } else { "hidden" }));
            }
            for seed in 1..=24u64 {
                let events = EventSchedule::new(seed);
                let demo: DemoMap = [(k.id, start)].into_iter().collect();
                // through the bright half of a supernova, or a comet's pass; heads on screen, in half heights
                let mut heads: Vec<DVec2> = vec![];
                let sn = k.id == SUPERNOVA.id;
                let open: Vec<bool> = (1..12)
                    .filter_map(|i| {
                        let t = start + k.duration * i as f64 / if sn { 24.0 } else { 12.0 };
                        let g = events.gpu_with_demo(t, &c, &cam, 480, &demo);
                        let v = if sn { g.sn_dir } else { g.comet_head };
                        if !(v[3] > 0.0) {
                            return None;
                        }
                        let d = normalize(xyz(v));
                        let uv = cam.project(d).unwrap_or(DVec2::new(2.0, 2.0));
                        heads.push(DVec2::new(uv.x * aspect, uv.y));
                        Some(SkyCover::new(&c, &cam, t).map_or(true, |s| s.open(d)) && (!crossing || uv.x.abs().max(uv.y.abs()) <= 1.0))
                    })
                    .collect();
                if open.is_empty() != hidden {
                    out.push(format!("{what}, seed {seed}: {}", if hidden { "drawn" } else { "not drawn" }));
                }
                if let (Some(a), Some(b)) = (heads.first(), heads.last()) {
                    if !sn && crossing && a.distance(*b) < 0.3 {
                        out.push(format!("{what}, seed {seed}: stands still"));
                    }
                }
                let need = if crossing && !sn { 4 } else { open.len() * 2 / 3 };
                if open.iter().filter(|&&o| o).count() < need {
                    out.push(format!("{what}, seed {seed}: behind the scene"));
                }
            }
        }
        out
    }

    fn eclipse() -> Vec<String> {
        let mut c = WallpaperConfig::default();
        c.set_scene(SceneKind::Eclipse);
        [(SUPERNOVA, 354.0, false), (SUPERNOVA, 364.0, false), (SUPERNOVA, 240.0, true),
         (SUPERNOVA, 400.0, true), (COMET, 356.0, false), (COMET, 200.0, true)]
            .into_iter()
            .filter(|&(k, t, h)| hidden_reason(k, &c, &[2.4], t).is_some() != h)
            .map(|(k, t, h)| format!("eclipse, event {} at {t}: Show Me has it {}", k.id, if h { "showing" } else { "hidden" }))
            .collect()
    }

    /// A spot on the ringed planet's middle ring is covered only while that's nearly opaque.
    fn ring(style: RingStyle, density: f64, covered: bool) -> Vec<String> {
        let mut c = WallpaperConfig::default();
        c.set_scene(SceneKind::RingedPlanet);
        c.ringed_ring_style = style;
        c.ringed_ring_density = density;
        c.ringed_tilt = 40.0;
        c.ringed_ring_width = 1.6;
        let cam = Camera::new(&c, 2.4);
        let a = scene_params::build(&c, 0.0, &cam, 0, 0, &EventSchedule::new(0), &DemoMap::new()).a;
        let n = xyz(a);
        let e = normalize(n.cross(cam.fwd));
        let spot = e * a[3] as f64 * (1.24 + (1.75 - 1.24) * 1.6);
        let open = SkyCover::new(&c, &cam, 0.0).map_or(true, |s| s.open(normalize(spot - cam.pos)));
        if open == covered {
            vec![format!("ringed planet, {style:?} at {density}: the middle ring is {}", if open { "open" } else { "covered" })]
        } else {
            vec![]
        }
    }

    #[test]
    fn events_keep_to_open_sky() {
        use SceneKind::*;
        let none = |_: &mut WallpaperConfig| {};
        let hold = |c: &mut WallpaperConfig| c.eclipse_motion = EclipseMotion::Hold;
        let failures: Vec<String> = [
            eclipse(),
            ring(RingStyle::Classic, 1.6, true),
            ring(RingStyle::Classic, 1.0, false),
            ring(RingStyle::Broad, 1.6, false),
            fails(GasGiant, 1.6, false, true, |c| { c.gas_distance = 1.4; c.gas_center_x = 0.0; c.gas_center_y = -0.6; }),
            fails(GasGiant, 0.5625, false, true, |c| { c.gas_distance = 1.3; c.gas_center_x = 0.0; c.gas_center_y = 0.0; }),
            fails(StellarSurface, 0.5625, false, true, |c| { c.star_zoom = 1.5; c.star_limb_y = 0.95; }),
            fails(AuroraOrbit, 2.4, false, false, none),
            fails(AuroraOrbit, 1.6, false, false, |c| c.aurora_horizon = 0.8),
            fails(GasGiant, 2.4, false, false, none),
            fails(GasGiant, 1.6, true, false, |c| { c.gas_distance = 1.2; c.gas_center_x = 0.0; c.gas_center_y = 0.0; }),
            fails(StellarSurface, 2.4, false, false, none),
            fails(StellarSurface, 2.4, false, false, |c| { c.star_zoom = 2.2; c.star_limb_y = 0.6; }),
            fails(StellarSurface, 0.56, true, false, |c| { c.star_zoom = 4.0; c.star_limb_y = 1.0; c.star_center_x = 0.0; }),
            fails(Eclipse, 2.4, false, false, hold),
            fails(Eclipse, 1.6, false, false, |c| { hold(c); c.eclipse_planet_size = 1.8; c.eclipse_planet_y = 0.4; }),
            fails(Eclipse, 2.4, true, false, |c| {
                hold(c);
                c.eclipse_atmosphere = true;
                c.eclipse_air_density = 3.0;
                c.eclipse_air_haze = 2.0;
                c.eclipse_clouds = 1.0;
            }),
            fails(RoguePlanet, 1.6, false, false, |c| c.rogue_size = 1.8),
            fails(RingedPlanet, 1.6, false, false, none),
            fails(BlackHole, 2.4, false, false, none),
        ]
        .concat();
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
}
