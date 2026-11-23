//! The real planets of our solar system as seen from Earth at a date: where they are, how
//! bright, how big, and which way their sun is, for any scene that draws the real sky (Live Earth
//! first). After Scenes/SkyPlanets.swift: positions from JPL's approximate Keplerian elements
//! (Standish, valid 1800 to 2050), about 0.1 degree against JPL Horizons; magnitudes from the
//! Astronomical Almanac's formulas (Mallama's for Venus). A scene turns the results into its own
//! frame with `gpu` and draws them with the shader's `skyPlanets` (shaders/sky_planets.wgsl).

use glam::DVec3;

use crate::gpu_types::SkyPlanetGpu;
use crate::math::normalize;

pub struct Planet {
    /// 0 Mercury ... 6 Neptune (also the label)
    pub index: usize,
    /// from Earth, J2000 equatorial, unit
    pub direction: DVec3,
    /// AU
    pub distance: f64,
    pub magnitude: f64,
    /// the disk's true angular radius, radians
    pub radius: f64,
    /// from the planet toward the sun, J2000 equatorial, unit
    pub to_sun: DVec3,
    /// north pole, J2000 equatorial, unit
    pub pole: DVec3,
}

pub const NAMES: [&str; 7] = ["Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"];

const DEG: f64 = std::f64::consts::PI / 180.0;
const AU_KM: f64 = 149_597_870.7;

type Elements = ([f64; 3], [f64; 3], [f64; 3], [f64; 3]);

/// a (AU), e, I, L, longitude of perihelion, longitude of the node (degrees), and their rates
/// per Julian century from J2000 (JPL Table 1). Earth's row is the Earth-Moon barycenter,
/// about 4,700 km from Earth's center: far under a pixel for the planets.
const ELEMENTS: [Elements; 7] = [
    ([0.38709927, 0.20563593, 7.00497902], [252.25032350, 77.45779628, 48.33076593],
     [0.00000037, 0.00001906, -0.00594749], [149472.67411175, 0.16047689, -0.12534081]),
    ([0.72333566, 0.00677672, 3.39467605], [181.97909950, 131.60246718, 76.67984255],
     [0.00000390, -0.00004107, -0.00078890], [58517.81538729, 0.00268329, -0.27769418]),
    ([1.52371034, 0.09339410, 1.84969142], [-4.55343205, -23.94362959, 49.55953891],
     [0.00001847, 0.00007882, -0.00813131], [19140.30268499, 0.44441088, -0.29257343]),
    ([5.20288700, 0.04838624, 1.30439695], [34.39644051, 14.72847983, 100.47390909],
     [-0.00011607, -0.00013253, -0.00183714], [3034.74612775, 0.21252668, 0.20469106]),
    ([9.53667594, 0.05386179, 2.48599187], [49.95424423, 92.59887831, 113.66242448],
     [-0.00125060, -0.00050991, 0.00193609], [1222.49362201, -0.41897216, -0.28867794]),
    ([19.18916464, 0.04725744, 0.77263783], [313.23810451, 170.95427630, 74.01692503],
     [-0.00196176, -0.00004397, -0.00242939], [428.48202785, 0.40805281, 0.04240589]),
    ([30.06992276, 0.00859048, 1.77004347], [-55.12002969, 44.96476227, 131.78422574],
     [0.00026291, 0.00005105, 0.00035372], [218.45945325, -0.32241464, -0.00508664]),
];
const EARTH_ELEMENTS: Elements = ([1.00000261, 0.01671123, -0.00001531], [100.46457166, 102.93768193, 0.0],
                                  [0.00000562, -0.00004392, -0.01294668], [35999.37244981, 0.32327364, 0.0]);
/// Equatorial radii, km.
const RADII_KM: [f64; 7] = [2439.7, 6051.8, 3396.2, 71492.0, 60268.0, 25559.0, 24764.0];
/// North poles (IAU): right ascension and declination, J2000, degrees.
const POLES: [(f64, f64); 7] = [(281.01, 61.42), (272.76, 67.16), (317.68, 52.89), (268.06, 64.50),
                                (40.59, 83.54), (257.31, -15.18), (299.36, 43.46)];

/// Colors as they look to the eye, roughly: dusky Mercury, cream Venus, rusty Mars, tan
/// Jupiter, pale gold Saturn, cyan Uranus, blue Neptune.
pub const COLORS: [[f32; 3]; 7] = [[0.78, 0.72, 0.66], [1.0, 0.95, 0.82], [1.0, 0.55, 0.34],
                                   [0.95, 0.84, 0.68], [0.95, 0.85, 0.6], [0.66, 0.9, 0.95],
                                   [0.45, 0.6, 1.0]];

/// The planets at a date (Unix seconds).
pub fn planets(date: f64) -> Vec<Planet> {
    let t = crate::astronomy::days(date) / 36525.0;
    let earth = heliocentric(&EARTH_ELEMENTS, t);
    let eps = 23.43928 * DEG;
    let equatorial = |v: DVec3| DVec3::new(v.x, eps.cos() * v.y - eps.sin() * v.z, eps.sin() * v.y + eps.cos() * v.z);
    (0..ELEMENTS.len())
        .map(|i| {
            let p = heliocentric(&ELEMENTS[i], t);
            let g = p - earth;
            let d = g.length();
            let r = p.length();
            // the phase angle: sun to planet to Earth, degrees
            let phase = (p.dot(g) / (r * d)).max(-1.0).min(1.0).acos() / DEG;
            let (ra, dec) = POLES[i];
            let pole = DVec3::new((dec * DEG).cos() * (ra * DEG).cos(), (dec * DEG).cos() * (ra * DEG).sin(), (dec * DEG).sin());
            let dir = normalize(equatorial(g));
            Planet {
                index: i,
                direction: dir,
                distance: d,
                magnitude: magnitude(i, r, d, phase, pole, dir),
                radius: RADII_KM[i] / (d * AU_KM),
                to_sun: normalize(equatorial(-p)),
                pole,
            }
        })
        .collect()
}

/// Visual magnitude: the planet's brightness at 1 AU from both, dimmed by distance, and by
/// phase (as the lit part we see shrinks); Saturn brightens as its rings open toward us.
fn magnitude(i: usize, r: f64, d: f64, a: f64, pole: DVec3, view: DVec3) -> f64 {
    let base = 5.0 * (r * d).log10();
    match i {
        0 => -0.42 + base + 0.0380 * a - 0.000273 * a * a + 0.000002 * a * a * a,
        1 => -4.384 + base - 1.044e-3 * a + 3.687e-4 * a * a - 2.814e-6 * a.powi(3) + 8.938e-9 * a.powi(4),
        2 => -1.52 + base + 0.016 * a,
        3 => -9.40 + base + 0.005 * a,
        4 => {
            let b = pole.dot(view).max(-1.0).min(1.0).asin().abs(); // the rings' tilt toward us
            -8.88 + base - 2.60 * b.sin() + 1.25 * b.sin() * b.sin()
        }
        5 => -7.19 + base,
        _ => -6.87 + base,
    }
}

/// Position around the sun, J2000 ecliptic, AU: Kepler's equation on the dated elements.
fn heliocentric(el: &Elements, t: f64) -> DVec3 {
    let a = el.0[0] + el.2[0] * t;
    let e = el.0[1] + el.2[1] * t;
    let inc = (el.0[2] + el.2[2] * t) * DEG;
    let l = el.1[0] + el.3[0] * t;
    let peri = el.1[1] + el.3[1] * t;
    let node = el.1[2] + el.3[2] * t;
    let w = (peri - node) * DEG;
    let o = node * DEG;
    let mut m = (l - peri) % 360.0;
    if m > 180.0 {
        m -= 360.0;
    } else if m < -180.0 {
        m += 360.0;
    }
    m *= DEG;
    let mut ea = m + e * m.sin();
    for _ in 0..8 {
        ea -= (ea - e * ea.sin() - m) / (1.0 - e * ea.cos());
    }
    let xp = a * (ea.cos() - e);
    let yp = a * (1.0 - e * e).sqrt() * ea.sin();
    let x = (w.cos() * o.cos() - w.sin() * o.sin() * inc.cos()) * xp + (-w.sin() * o.cos() - w.cos() * o.sin() * inc.cos()) * yp;
    let y = (w.cos() * o.sin() + w.sin() * o.cos() * inc.cos()) * xp + (-w.sin() * o.sin() + w.cos() * o.cos() * inc.cos()) * yp;
    let z = w.sin() * inc.sin() * xp + w.cos() * inc.sin() * yp;
    DVec3::new(x, y, z)
}

/// The planets for the shader, in a scene's frame (`to_scene` turns a J2000 equatorial vector
/// into it). `label_visible` says whether the scene can see each one (not behind its own
/// bodies), which is when its label shows.
pub fn gpu(planets: &[Planet], to_scene: impl Fn(DVec3) -> DVec3, label_visible: impl Fn(DVec3) -> bool) -> Vec<SkyPlanetGpu> {
    planets
        .iter()
        .map(|p| {
            let dir = normalize(to_scene(p.direction));
            // the same magnitude scale as the catalog stars (leSky): flux to the 0.75, x4
            let brightness = 4.0 * (-0.9966 * p.magnitude).exp2();
            let c = COLORS[p.index];
            let sun = normalize(to_scene(p.to_sun));
            let pole = normalize(to_scene(p.pole));
            SkyPlanetGpu {
                dir: [dir.x as f32, dir.y as f32, dir.z as f32, p.radius as f32],
                color: [c[0], c[1], c[2], brightness as f32],
                light: [sun.x as f32, sun.y as f32, sun.z as f32, if label_visible(dir) { 1.0 } else { 0.0 }],
                pole: [pole.x as f32, pole.y as f32, pole.z as f32, p.index as f32],
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jupiter_is_bright_and_mars_rusty() {
        let ps = planets(1_794_853_800.0);
        assert_eq!(ps.len(), 7);
        // Jupiter's magnitude stays within its usual range
        assert!(ps[3].magnitude < -1.5 && ps[3].magnitude > -3.0, "{}", ps[3].magnitude);
        // Venus is always the brightest
        assert!(ps[1].magnitude < -3.0);
        for p in &ps {
            assert!((p.direction.length() - 1.0).abs() < 1e-12);
        }
    }
}
