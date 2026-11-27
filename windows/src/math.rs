//! Small numeric helpers shared by the scene model (Support/Math.swift in the macOS app).
#![allow(dead_code)]

use glam::{DVec2, DVec3};

/// SplitMix64: small, fast, and seedable, so scene layouts and events are reproducible. The
/// wrapping arithmetic matches Swift's `&+` and `&*`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rng {
    pub state: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng { state: seed }
    }

    pub fn next(&mut self) -> f64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn range(&mut self, a: f64, b: f64) -> f64 {
        a + (b - a) * self.next()
    }
}

pub fn smoothstep(a: f64, b: f64, x: f64) -> f64 {
    let t = ((x - a) / (b - a)).max(0.0).min(1.0);
    t * t * (3.0 - 2.0 * t)
}

/// simd_normalize: x times the reciprocal of its length (glam's `normalize` does the same).
pub fn normalize(v: DVec3) -> DVec3 {
    v * (1.0 / v.length_squared().sqrt())
}

/// simd_mix: a + t (b - a). glam's `lerp` rounds differently, so it isn't used.
pub fn mix(a: DVec3, b: DVec3, t: f64) -> DVec3 {
    a + (b - a) * t
}

/// Swift's `SIMD4<Float>(SIMD3<Double>)`: each component rounded to Float, w = 0.
pub fn v4(v: DVec3) -> [f32; 4] {
    [v.x as f32, v.y as f32, v.z as f32, 0.0]
}

/// `SIMD4(SIMD3<Float>(v), w)`.
pub fn v4w(v: DVec3, w: f32) -> [f32; 4] {
    [v.x as f32, v.y as f32, v.z as f32, w]
}

pub fn v3w(v: [f32; 3], w: f32) -> [f32; 4] {
    [v[0], v[1], v[2], w]
}

pub fn dvec2(x: f64, y: f64) -> DVec2 {
    DVec2::new(x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rng_matches_splitmix64() {
        // reference values of SplitMix64 seeded with 0 (the first output is 0xE220A8397B1DCDAF)
        let mut r = Rng::new(0);
        let first = r.next();
        assert_eq!(first, (0xE220_A839_7B1D_CDAFu64 >> 11) as f64 / (1u64 << 53) as f64);
    }
}
