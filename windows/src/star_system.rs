//! Star positions and lights for the star system scenes (Scenes/StarSystem.swift).
#![allow(dead_code)]

use std::f64::consts::PI;

use glam::DVec3;

use crate::config::{SceneKind, StarType, WallpaperConfig};
use crate::gpu_types::{LightGpu, StarGpu};

/// Star positions for the binary and trinary scenes at time t (empty for the other scenes).
pub fn stars(c: &WallpaperConfig, t: f64) -> Vec<StarGpu> {
    // the orbits are tipped 8 degrees toward us
    let inc = 8.0 / 180.0 * PI;
    let orbit_point = |r: f64, angle: f64| -> DVec3 {
        DVec3::new(angle.cos() * r, -angle.sin() * r * inc.sin(), angle.sin() * r * inc.cos())
    };
    let gpu = |ty: StarType, p: DVec3, i: usize| -> StarGpu {
        let col = ty.color();
        let spin = ((2.0 * PI * t / (8.0 * 60.0) + i as f64) % (2.0 * PI)) as f32;
        StarGpu {
            pos: [p.x as f32, p.y as f32, p.z as f32, ty.radius() as f32],
            color: [col.r, col.g, col.b, ty.glow() as f32],
            misc: [spin, i as f32 * 13.7 + 2.0, ty.activity() as f32, 0.0],
        }
    };
    let period = c.star_orbit_minutes * 60.0;
    match c.scene {
        SceneKind::Binary => {
            let (a, b) = (c.binary_stars[0], c.binary_stars[1]);
            let sep = c.star_separation.max((a.radius() + b.radius()) * 1.4);
            let ang = 2.0 * PI * t / period;
            let m = a.mass() + b.mass();
            vec![gpu(a, orbit_point(sep * b.mass() / m, ang), 0),
                 gpu(b, orbit_point(sep * a.mass() / m, ang + PI), 1)]
        }
        SceneKind::Trinary => {
            let (a, b, cc) = (c.trinary_stars[0], c.trinary_stars[1], c.trinary_stars[2]);
            let inner = (c.star_separation * 0.6).max((a.radius() + b.radius()) * 1.4);
            let outer = (c.star_separation * 2.0).max(inner + cc.radius() * 2.0 + 3.0);
            let m_ab = a.mass() + b.mass();
            let m_all = m_ab + cc.mass();
            // the inner pair whirls quickly; the third star swings around them slowly
            let outer_ang = 2.0 * PI * t / (period * 6.0);
            let pair_center = orbit_point(outer * cc.mass() / m_all, outer_ang);
            let inner_ang = 2.0 * PI * t / period;
            vec![gpu(a, pair_center + orbit_point(inner * b.mass() / m_ab, inner_ang), 0),
                 gpu(b, pair_center + orbit_point(inner * a.mass() / m_ab, inner_ang + PI), 1),
                 gpu(cc, orbit_point(outer * m_ab / m_all, outer_ang + PI), 2)]
        }
        _ => Vec::new(),
    }
}

/// The point lights that shade the planets: the disk for the black hole, the far universe for
/// the wormhole, and each star in the star systems.
pub fn lights(c: &WallpaperConfig, stars: &[StarGpu]) -> Vec<LightGpu> {
    match c.scene {
        SceneKind::BlackHole => {
            let p = &c.palette;
            // Float math, as in Swift
            let col = [
                p.receding.r * 0.6 + p.core.r * 0.4,
                p.receding.g * 0.6 + p.core.g * 0.4,
                p.receding.b * 0.6 + p.core.b * 0.4,
            ];
            vec![LightGpu { pos: [0.0, 0.0, 0.0, 1.0], color: [col[0], col[1], col[2], 1.0] }]
        }
        SceneKind::Wormhole => {
            let f = c.palette.far_a;
            let col = [f.r * 0.5 + 0.25, f.g * 0.5 + 0.25, f.b * 0.5 + 0.25];
            vec![LightGpu { pos: [0.0, 0.0, 0.0, 0.7], color: [col[0], col[1], col[2], 1.0] }]
        }
        SceneKind::Binary | SceneKind::Trinary => stars
            .iter()
            .map(|s| LightGpu {
                pos: [s.pos[0], s.pos[1], s.pos[2], 0.9],
                color: [s.color[0], s.color[1], s.color[2], 1.0],
            })
            .collect(),
        _ => Vec::new(),
    }
}
