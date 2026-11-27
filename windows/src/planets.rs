//! The orbiting planets of the black hole and star system scenes (Scenes/Planets.swift).
#![allow(dead_code)]

use std::f64::consts::PI;

use crate::camera::SceneGeometry;
use crate::config::{SceneKind, WallpaperConfig};
use crate::gpu_types::PlanetGpu;
use crate::math::Rng;

/// One planet's orbit and look, laid out from the planet seed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlanetSpec {
    /// lensed scenes: which bake shell; -1 = free orbit (star systems)
    pub shell: i64,
    pub orbit: f64,
    pub radius: f64,
    pub period_minutes: f64,
    /// degrees
    pub inclination: f64,
    /// degrees
    pub node: f64,
    /// degrees at launch
    pub phase: f64,
    pub color_a: [f32; 3],
    pub color_b: [f32; 3],
    pub bands: f32,
    pub atmosphere: f32,
    pub seed: f32,
    pub spin_minutes: f64,
    /// 0 gas giant, 1 ice giant, 2 rocky, 3 lava (see the shader's PlanetLook)
    pub kind: i64,
    /// outer ring radius in planet radii, 0 = none
    pub rings: f64,
}

impl PlanetSpec {
    pub fn gpu(&self, t: f64) -> PlanetGpu {
        let a = (self.phase / 180.0 * PI) + 2.0 * PI * t / (self.period_minutes * 60.0);
        let inc = self.inclination / 180.0 * PI;
        let nd = self.node / 180.0 * PI;
        // circle in the disk plane (same direction as the disk), tilted about x, then turned about y
        let x0 = a.cos() * self.orbit;
        let z0 = a.sin() * self.orbit;
        let y1 = -z0 * inc.sin();
        let z1 = z0 * inc.cos();
        let x2 = x0 * nd.cos() - z1 * nd.sin();
        let z2 = x0 * nd.sin() + z1 * nd.cos();
        let spin = ((2.0 * PI * t / (self.spin_minutes * 60.0)) % (2.0 * PI)) as f32;
        PlanetGpu {
            center: [x2 as f32, y1 as f32, z2 as f32, self.shell as f32],
            color_a: [self.color_a[0], self.color_a[1], self.color_a[2], self.radius as f32],
            color_b: [self.color_b[0], self.color_b[1], self.color_b[2], self.seed],
            misc: [spin, self.bands, self.atmosphere, (self.kind * 8) as f32 + self.rings as f32],
        }
    }
}

/// Rocky worlds use `a` for land and `b` for sea; lava worlds `a` for the glow and `b` for the
/// crust. `ring_chance` / `ring_size`: how often it has rings, and how far out (planet radii).
struct Style {
    a: [f32; 3],
    b: [f32; 3],
    bands: f32,
    atmosphere: f32,
    kind: i64,
    ring_chance: f32,
    ring_size: f64,
}

const STYLES: [Style; 7] = [
    // rust giant
    Style { a: [0.95, 0.42, 0.14], b: [0.30, 0.08, 0.04], bands: 7.0, atmosphere: 0.25, kind: 0, ring_chance: 0.4, ring_size: 2.0 },
    // ice giant
    Style { a: [0.80, 0.90, 1.00], b: [0.22, 0.34, 0.60], bands: 3.0, atmosphere: 0.8, kind: 1, ring_chance: 0.5, ring_size: 1.8 },
    // ocean world
    Style { a: [0.45, 0.58, 0.32], b: [0.03, 0.10, 0.35], bands: 12.0, atmosphere: 1.0, kind: 2, ring_chance: 0.0, ring_size: 0.0 },
    // banded gas giant
    Style { a: [0.95, 0.82, 0.60], b: [0.55, 0.38, 0.22], bands: 14.0, atmosphere: 0.3, kind: 0, ring_chance: 1.0, ring_size: 2.3 },
    // lava
    Style { a: [1.00, 0.35, 0.05], b: [0.10, 0.03, 0.02], bands: 2.0, atmosphere: 0.1, kind: 3, ring_chance: 0.0, ring_size: 0.0 },
    // jungle
    Style { a: [0.35, 0.85, 0.45], b: [0.05, 0.25, 0.20], bands: 5.0, atmosphere: 0.7, kind: 2, ring_chance: 0.0, ring_size: 0.0 },
    // violet
    Style { a: [0.75, 0.55, 1.00], b: [0.20, 0.10, 0.40], bands: 9.0, atmosphere: 0.6, kind: 0, ring_chance: 0.3, ring_size: 2.0 },
];

/// PlanetFactory.make: the layout depends only on the planet settings and the scene. Swift
/// caches it; it's cheap enough to lay out every frame here.
pub fn make(c: &WallpaperConfig) -> Vec<PlanetSpec> {
    if !c.scene.has_planets() {
        return Vec::new();
    }
    // UInt64(truncatingIfNeeded:) then &* and &+
    let mut rng = Rng::new((c.planet_seed as u64).wrapping_mul(0x5851_F42D_4C95_7F2D).wrapping_add(7));
    let mut order: Vec<usize> = (0..STYLES.len()).collect();
    for i in (0..order.len()).rev() {
        let j = (rng.next() * (i + 1) as f64) as usize;
        order.swap(i, j);
    }
    let count = c.planet_count.min(6).max(0) as usize;
    (0..count)
        .map(|i| {
            let style = &STYLES[order[i % STYLES.len()]];
            let (shell, orbit) = match c.scene {
                SceneKind::BlackHole | SceneKind::Wormhole => {
                    let shell = if i % 2 == 0 { 1 } else { 0 };
                    (shell as i64, SceneGeometry::SHELL_ORBITS[shell])
                }
                SceneKind::Binary => (-1, rng.range(8.5, 15.0)),
                SceneKind::Trinary => (-1, rng.range(7.0, 10.0)),
                _ => (-1, 10.0),
            };
            let radius = (rng.range(0.14, 0.32) * c.planet_size).min(SceneGeometry::MAX_PLANET_RADIUS);
            // Swift evaluates the initializer's arguments in order, so the draws go
            // inclination, node, phase, seed, spin.
            let inclination = rng.range(-32.0, 32.0);
            let node = rng.range(-90.0, 90.0);
            let phase = rng.range(0.0, 360.0);
            let seed = rng.range(0.0, 50.0) as f32;
            let spin_minutes = rng.range(3.0, 8.0);
            let mut spec = PlanetSpec {
                shell, orbit, radius,
                period_minutes: c.planet_orbit_minutes * (orbit / 11.5).powf(1.5),
                inclination, node, phase,
                color_a: style.a, color_b: style.b, bands: style.bands, atmosphere: style.atmosphere,
                seed, spin_minutes,
                kind: style.kind,
                rings: 0.0,
            };
            // decided from the planet's own seed (Float math), so adding rings didn't reshuffle
            // existing layouts
            let roll = (spec.seed * 7.31f32) % 1.0f32;
            if c.planet_rings && roll < style.ring_chance {
                spec.rings = style.ring_size;
            }
            spec
        })
        .collect()
}

/// `PlanetFactory.make(c).map { $0.gpu(elapsed:) }`.
pub fn planets_gpu(c: &WallpaperConfig, elapsed: f64) -> Vec<PlanetGpu> {
    make(c).iter().map(|p| p.gpu(elapsed)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_is_deterministic() {
        let c = WallpaperConfig::default();
        let a = planets_gpu(&c, 300.0);
        let b = planets_gpu(&c, 300.0);
        assert_eq!(a.len(), 3);
        assert_eq!(bytemuck::cast_slice::<_, u8>(&a), bytemuck::cast_slice::<_, u8>(&b));
        // black hole planets alternate between the outer and inner shells
        assert_eq!(a[0].center[3], 1.0);
        assert_eq!(a[1].center[3], 0.0);
    }

    #[test]
    fn gas_giant_has_no_planets() {
        let mut c = WallpaperConfig::default();
        c.scene = SceneKind::GasGiant;
        assert!(planets_gpu(&c, 0.0).is_empty());
    }
}
