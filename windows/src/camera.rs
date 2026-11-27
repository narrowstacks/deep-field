//! Fixed scene geometry and the camera basis (Scenes/Camera.swift in the macOS app).
#![allow(dead_code)]

use glam::{DVec2, DVec3};

use crate::config::{PhoneFraming, SceneKind, WallpaperConfig};
use crate::math::normalize;

/// Fixed scene geometry. Lengths are in Schwarzschild radii of the black hole.
pub struct SceneGeometry;

impl SceneGeometry {
    /// the innermost stable circular orbit
    pub const DISK_IN: f32 = 3.0;
    pub const CAM_DIST: f64 = 24.0;
    /// camera roll, radians
    pub const ROLL: f64 = -0.035;
    /// seconds; the disk texture's cross-fade loop
    pub const FLOW_PERIOD: f32 = 48.0;
    /// Orbit radii of the two planet shells used by the lensed scenes.
    pub const SHELL_ORBITS: [f64; 2] = [7.0, 11.5];
    /// The bake shells sit this far outside each orbit, so every ray that can touch a planet
    /// crosses them.
    pub const MAX_PLANET_RADIUS: f64 = 0.65;

    pub fn shell_radii() -> [f32; 2] {
        [(Self::SHELL_ORBITS[0] + Self::MAX_PLANET_RADIUS) as f32,
         (Self::SHELL_ORBITS[1] + Self::MAX_PLANET_RADIUS) as f32]
    }
}

/// Camera basis matching the bake kernels' `cameraRay`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Camera {
    pub pos: DVec3,
    pub fwd: DVec3,
    pub right: DVec3,
    pub up: DVec3,
    pub aspect: f64,
    pub tan_half: f64,
    pub roll: f64,
    /// The aim point and distance the bake uses (the aim differs from the scene's in portrait).
    pub look: DVec2,
    pub distance: f64,
    /// Screen-space scenes (comet, star close-up): their units per half screen height, and where
    /// their subject sits (v in [-1, 1]). 1 and 0 on the desktop.
    pub screen_scale: f64,
    pub subject_y: f64,
    pub portrait: bool,
}

impl Camera {
    /// Where the camera aims, relative to the scene's center. The wormhole is framed off-center;
    /// the tidal disruption aims between the hole and its star.
    pub fn look_for(scene: SceneKind) -> DVec2 {
        match scene {
            SceneKind::Wormhole => DVec2::new(-6.5, 1.2),
            SceneKind::TidalDisruption => DVec2::new(-3.5, 0.0),
            _ => DVec2::ZERO,
        }
    }

    /// The tidal disruption pulls back so the star beside the hole fits.
    pub fn distance_for(scene: SceneKind) -> f64 {
        if scene == SceneKind::TidalDisruption { 40.0 } else { SceneGeometry::CAM_DIST }
    }

    pub fn new(c: &WallpaperConfig, aspect: f64) -> Camera {
        let mut look = Camera::look_for(c.scene);
        let distance = Camera::distance_for(c.scene);
        let e = c.camera_tilt() / 180.0 * std::f64::consts::PI;
        let (tan_half, screen_scale, subject_y, portrait);
        if let Some(f) = c.phone_framing {
            let (half_width, l_subject_y, look_x) = PhoneFraming::layout(c.scene);
            let zoom = f.zoom.max(0.25).min(4.0);
            let v = (l_subject_y + 2.0 * f.shift).max(-0.9).min(0.9);
            let screen_space = matches!(c.scene, SceneKind::Comet | SceneKind::StellarSurface | SceneKind::Eclipse);
            if screen_space {
                // the sky keeps the desktop's field of view; the subject scales itself
                tan_half = 0.27f64.max(0.70 / aspect);
                screen_scale = half_width / aspect / zoom;
            } else {
                tan_half = half_width / aspect / zoom;
                screen_scale = 1.0;
                // aim above the subject so it sits at v: raise the aim point by the height that
                // subtends that angle from the camera
                look = DVec2::new(look_x, look.y - v * tan_half * distance / e.cos());
            }
            subject_y = v;
            portrait = true;
        } else {
            // keep the scene's horizontal extent roughly constant across aspect ratios
            tan_half = 0.27f64.max(0.70 / aspect);
            screen_scale = 1.0;
            subject_y = 0.0;
            portrait = false;
        }
        let pos = DVec3::new(0.0, e.sin(), -e.cos()) * distance;
        let fwd = normalize(DVec3::new(look.x, look.y, 0.0) - pos);
        let right = normalize(DVec3::new(0.0, 1.0, 0.0).cross(fwd));
        let up = fwd.cross(right);
        Camera {
            pos, fwd, right, up, aspect, tan_half,
            roll: SceneGeometry::ROLL,
            look, distance, screen_scale, subject_y, portrait,
        }
    }

    /// Direction from the camera to the scene's center (the hole, throat, or barycenter).
    pub fn center(&self) -> DVec3 {
        normalize(-self.pos)
    }

    /// Screen position in [-1, 1] (x right, y up) of a direction, or None if it's behind the camera.
    pub fn project(&self, d: DVec3) -> Option<DVec2> {
        let z = d.dot(self.fwd);
        if !(z > 1e-4) {
            return None;
        }
        let rx = d.dot(self.right) / z / self.tan_half;
        let ry = d.dot(self.up) / z / self.tan_half;
        let (s, c) = (self.roll.sin(), self.roll.cos());
        let x = c * rx + s * ry;
        let y = -s * rx + c * ry;
        Some(DVec2::new(x / self.aspect, y))
    }

    /// Camera ray for a screen position in [-1, 1].
    pub fn ray(&self, u: f64, v: f64) -> DVec3 {
        let x = u * self.aspect;
        let y = v;
        let (s, c) = (self.roll.sin(), self.roll.cos());
        let rx = c * x - s * y;
        let ry = s * x + c * y;
        normalize(self.fwd + (rx * self.right + ry * self.up) * self.tan_half)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_black_hole_basis_at_16_10() {
        let c = WallpaperConfig::default();
        let cam = Camera::new(&c, 16.0 / 10.0);
        let e = 6.3 / 180.0 * std::f64::consts::PI;
        assert!((cam.pos - DVec3::new(0.0, e.sin() * 24.0, -e.cos() * 24.0)).length() < 1e-12);
        // aimed at the hole, level horizon before the roll
        assert!((cam.fwd - DVec3::new(0.0, -e.sin(), e.cos())).length() < 1e-12);
        assert!((cam.right - DVec3::new(1.0, 0.0, 0.0)).length() < 1e-12);
        assert!((cam.up - DVec3::new(0.0, e.cos(), e.sin())).length() < 1e-12);
        assert_eq!(cam.tan_half, 0.70 / 1.6);
        assert_eq!(cam.screen_scale, 1.0);
        assert!(!cam.portrait);
        // the hole projects to the middle of the screen
        let p = cam.project(cam.center()).unwrap();
        assert!(p.length() < 1e-12);
        // ray and project are inverses
        let d = cam.ray(0.3, -0.4);
        let q = cam.project(d).unwrap();
        assert!((q - DVec2::new(0.3, -0.4)).length() < 1e-12);
    }

    #[test]
    fn wide_aspect_keeps_minimum_fov() {
        let cam = Camera::new(&WallpaperConfig::default(), 3.0);
        assert_eq!(cam.tan_half, 0.27);
    }
}
