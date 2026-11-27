//! Live Earth's SceneParams, planets and labels (Scenes/SceneParams.swift, MARK: Live Earth).
//! The home location is the configured homeLatitude / homeLongitude; the Mac's option to follow
//! the device's location (homeFromDevice) isn't on Windows yet.

use std::sync::atomic::{AtomicU64, Ordering};

use glam::{DQuat, DVec3};

use crate::astronomy;
use crate::camera::Camera;
use crate::config::WallpaperConfig;
use crate::gpu_types::{SceneParamsGpu, SkyPlanetGpu};
use crate::math::{normalize, v4w};
use crate::sky_planets;

/// Dev only (`--earth-timelapse`): Earth seconds per second of the scene's clock, 0 for real
/// time (an f64's bits).
static TIME_LAPSE: AtomicU64 = AtomicU64::new(0);

pub fn set_time_lapse(rate: f64) {
    TIME_LAPSE.store(rate.to_bits(), Ordering::Relaxed);
}

fn time_lapse() -> f64 {
    f64::from_bits(TIME_LAPSE.load(Ordering::Relaxed))
}

/// Now, as Unix seconds.
pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// The moment Live Earth shows (Unix seconds): now, or the time it's frozen at.
pub fn date(c: &WallpaperConfig, t: f64) -> f64 {
    let base = if c.earth_freeze_time { c.earth_frozen_time } else { now() };
    base + time_lapse() * t
}

fn d3(v: [f32; 4]) -> DVec3 {
    DVec3::new(v[0] as f64, v[1] as f64, v[2] as f64)
}

/// Live Earth's planets for the shader (skyP), in its Earth-fixed frame, from the frame's scene
/// parameters: the sky turn in rows k, l, m, the camera at a, the Moon at f. A label shows only
/// while its planet isn't behind Earth or the Moon.
pub fn planets(c: &WallpaperConfig, t: f64, p: &SceneParamsGpu) -> Vec<SkyPlanetGpu> {
    if !c.earth_planets {
        return Vec::new();
    }
    let rows = [d3(p.k), d3(p.l), d3(p.m)];
    // the rows take Earth-fixed to J2000; their transpose takes J2000 back
    let to_scene = |j: DVec3| rows[0] * j.x + rows[1] * j.y + rows[2] * j.z;
    let cam = d3(p.a);
    let moon = d3(p.f);
    let moon_r = p.f[3] as f64;
    let blocked = |center: DVec3, r: f64, dir: DVec3| {
        let oc = cam - center;
        let b = oc.dot(dir);
        b < 0.0 && oc.length_squared() - b * b < r * r
    };
    let clear = |dir: DVec3| !blocked(DVec3::ZERO, 1.02, dir) && !blocked(moon, moon_r, dir);
    sky_planets::gpu(&sky_planets::planets(date(c, t)), to_scene, clear)
}

/// Where the planets' labels go, for Renderer::encode_labels: each name's left edge and vertical
/// center in target pixels, which name, and the font's pixel size. Found by projecting each
/// planet through the same camera the frame was drawn with (Camera::ray, run backward from
/// the scene's view turn in b, c, d). The font is scaled to look about the same size on
/// screen at any pixel size.
pub fn labels(c: &WallpaperConfig, planets: &[SkyPlanetGpu], p: &SceneParamsGpu, cam: &Camera,
              width: u32, height: u32) -> Vec<[f32; 4]> {
    if !c.earth_planet_labels {
        return Vec::new();
    }
    let font = (3.0 / c.pixel_size.max(1) as f64).round().max(1.0);
    let pixel_angle = 2.0 * cam.tan_half / height as f64;
    let axes = [d3(p.b), d3(p.c), d3(p.d)];
    let (w, h) = (width as f64, height as f64);
    let mut placed: Vec<[f32; 4]> = planets
        .iter()
        .filter_map(|pl| {
            if pl.light[3] <= 0.5 {
                return None;
            }
            let wd = d3(pl.dir);
            let l = DVec3::new(wd.dot(axes[0]), wd.dot(axes[1]), wd.dot(axes[2]));
            if l.z <= 0.0 {
                return None;
            }
            let rx = l.x / l.z / cam.tan_half;
            let ry = l.y / l.z / cam.tan_half;
            let x = cam.roll.cos() * rx + cam.roll.sin() * ry;
            let y = -cam.roll.sin() * rx + cam.roll.cos() * ry;
            let px = (x / cam.aspect + 1.0) / 2.0 * w;
            let py = (1.0 - y) / 2.0 * h;
            if !(px > -10.0 && px < w && py > -10.0 && py < h + 10.0) {
                return None;
            }
            // clear of the planet's drawn disk (and Saturn's rings)
            let saturn = pl.pole[3] == 4.0;
            let drawn = pl.dir[3] as f64 * c.earth_planet_size * if saturn { 2.3 } else { 1.0 } / pixel_angle;
            let left = px + drawn.max(1.0) + 2.0 * font;
            Some([left.round() as f32, py.round() as f32, pl.pole[3], font as f32])
        })
        .collect();
    // Planets close together in the sky (Mars passing Jupiter) would print their names over
    // each other: going down the screen, move a label below any earlier one it would hit.
    let line_height = (9.0 * font) as f32;
    let width_per_char = (6.0 * font) as f32;
    // a stable sort, like Swift's sorted(by:) on these few items
    placed.sort_by(|a, b| a[1].partial_cmp(&b[1]).unwrap_or(std::cmp::Ordering::Equal));
    let mut out: Vec<[f32; 4]> = Vec::new();
    for mut l in placed {
        let lw = sky_planets::NAMES[l[2] as usize].len() as f32 * width_per_char;
        for o in &out {
            let ow = sky_planets::NAMES[o[2] as usize].len() as f32 * width_per_char;
            if l[0] < o[0] + ow && o[0] < l[0] + lw && (l[1] - o[1]).abs() < line_height {
                l[1] = o[1] + line_height;
            }
        }
        out.push(l);
    }
    out
}

pub fn build(c: &WallpaperConfig, t: f64, cam: &Camera, width: u32, height: u32) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let date = date(c, t);
    let home = astronomy::point(c.home_latitude, c.home_longitude);
    let pos = home * c.earth_distance;
    // looking straight down at the chosen place with north up: east is on the right
    let fwd = -home;
    let mut north = DVec3::new(0.0, 0.0, 1.0) - home * home.z;
    if north.length() < 1e-6 {
        north = DVec3::new(-1.0, 0.0, 0.0) - home * home.x; // at a pole
    }
    let up = normalize(north);
    let right = fwd.cross(up);
    // turn the view so Earth's center lands where the settings put it on screen
    let aspect = width as f64 / height.max(1) as f64;
    let to_center = normalize(DVec3::new(c.earth_center_x * cam.tan_half * aspect, c.earth_center_y * cam.tan_half, 1.0));
    let q = DQuat::from_rotation_arc(to_center, DVec3::Z);
    let world = |v: DVec3| {
        let r = q.mul_vec3(v);
        v4w(r.x * right + r.y * up + r.z * fwd, 0.0)
    };
    let sun = astronomy::sun(date);
    let moon = astronomy::moon(date);
    let moon_radius = 1737.4 / 6371.0;
    let night = home.dot(sun) < 0.0;
    p.a = v4w(pos, 0.0);
    p.b = world(DVec3::X);
    p.c = world(DVec3::Y);
    p.d = world(DVec3::Z);
    p.e = v4w(sun, if c.earth_hide_sun_at_night && night { 0.0 } else { 1.0 });
    p.f = v4w(moon, (moon_radius * c.earth_moon_size) as f32);
    p.g = [if c.earth_clouds { c.earth_cloud_amount as f32 } else { 0.0 },
           if c.earth_aurora { c.earth_aurora_brightness as f32 } else { 0.0 },
           c.earth_city_lights as f32, c.earth_moonlight as f32];
    // x, y, z: which maps are bound (the renderer sets them); w: the season, 0 mid-January to
    // 1 mid-July, blending the two surface maps so snow comes and goes
    let day_of_year = astronomy::day_of_year(date);
    p.h = [0.0, 0.0, 0.0, (0.5 - 0.5 * (2.0 * std::f64::consts::PI * (day_of_year - 15.0) / 365.25).cos()) as f32];
    p.i = v4w(home, if c.earth_marker { 1.0 } else { 0.0 });
    // z: whether the star maps are bound (the renderer sets it)
    // w: the Moon is close enough to the sun for its shadow to touch Earth (within about 1.3
    // degrees seen from Earth's center, allowing for the parallax of Earth's radius), so the
    // shader only works out the shadow during a solar eclipse
    let sun_moon = sun.dot(normalize(moon)).max(-1.0).min(1.0).acos();
    let eclipse = sun_moon < (1.0 / moon.length()).asin() + 0.012;
    p.j = [c.earth_atmosphere as f32, moon_radius as f32, 0.0, if eclipse { 1.0 } else { 0.0 }];
    // the turn from Earth-fixed directions to the stars' catalog frame (J2000), rows in k, l, m
    let sky = astronomy::earth_fixed_to_j2000(date);
    p.k = v4w(sky[0], 0.0);
    p.l = v4w(sky[1], 0.0);
    p.m = v4w(sky[2], 0.0);
    p.n = [c.earth_stars as f32, c.earth_milky_way as f32, c.earth_aurora_speed as f32, 0.0];
    // the planets: how many are bound (the renderer sets it), their size, labels on
    p.o = [0.0, c.earth_planet_size as f32, if c.earth_planet_labels { 1.0 } else { 0.0 }, 0.0];
    p
}
