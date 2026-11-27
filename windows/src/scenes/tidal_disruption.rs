//! Star meets black hole (Scenes/TidalDisruption.swift): a star parked beside the hole,
//! overflowing toward it, feeding a disk that is already there. The star, stream and jets are
//! traced in the bake, so the frame builder only carries colors.

use std::f64::consts::PI;

use glam::DVec3;

use crate::camera::Camera;
use crate::config::{SceneKind, TdeDiskColors, WallpaperConfig};
use crate::events::{DemoMap, EventSchedule};
use crate::gpu_types::SceneParamsGpu;
use crate::math::v3w;
use crate::palette::{level, palette_gpu, rgb};
use crate::scene_params::TDE_DISK_OUTER;

/// TDEGeometry: the star and stream geometry, fixed for a given config (it feeds the bake).
struct TdeGeometry {
    /// Star center (in the disk plane) and its radius across the stretch.
    center: DVec3,
    radius: f64,
    /// Semi-axes along the line to the hole: the stretched near half, the far half.
    near_axis: f64,
    far_axis: f64,
    /// Stream: angle where it leaves the star, start and merge radii, how far round it winds
    /// (radians) by the merge, and where it ends past the merge (in units of that winding).
    start_angle: f64,
    start_radius: f64,
    merge_radius: f64,
    winding: f64,
    end: f64,
    /// Stream half-width at the star and at the merge.
    width0: f64,
    width1: f64,
}

impl TdeGeometry {
    fn new(c: &WallpaperConfig) -> Self {
        let distance = c.tde_star_distance.max(15.0).min(35.0);
        let r = 1.9 * c.tde_star.radius().sqrt() * c.tde_star_size.max(0.3).min(2.5);
        // left of the hole and toward the camera, swung further round when far out so the star
        // stays in frame: x / (camera distance - z) is held at about the same value
        let cam_dist = Camera::distance_for(SceneKind::TidalDisruption);
        let (mut lo, mut hi) = (PI + 0.6, 1.5 * PI);
        for _ in 0..30 {
            let mid = (lo + hi) / 2.0;
            if distance * mid.cos() / (cam_dist + distance * mid.sin()) < -0.55 { lo = mid } else { hi = mid }
        }
        let angle = (lo + hi) / 2.0;
        let near_axis = r * 1.45;
        TdeGeometry {
            center: DVec3::new(angle.cos(), 0.0, angle.sin()) * distance,
            radius: r,
            // the more the star fills its Roche lobe, the longer its tip
            near_axis,
            far_axis: r * 1.06,
            start_angle: angle,
            start_radius: distance - near_axis * 0.6,
            merge_radius: TDE_DISK_OUTER * 0.86,
            winding: 2.5,
            end: 1.85,
            width0: r * 0.6,
            width1: 0.45,
        }
    }

    /// Bake parameters: a = (center, radius), b = (near axis, far axis, start angle, end),
    /// c = (start radius, merge radius, winding, 0), d = (width at star, width at merge, 0, 0).
    fn bake(&self) -> SceneParamsGpu {
        let mut p = SceneParamsGpu::default();
        p.a = [self.center.x as f32, self.center.y as f32, self.center.z as f32, self.radius as f32];
        p.b = [self.near_axis as f32, self.far_axis as f32, self.start_angle as f32, self.end as f32];
        p.c = [self.start_radius as f32, self.merge_radius as f32, self.winding as f32, 0.0];
        p.d = [self.width0 as f32, self.width1 as f32, 0.0, 0.0];
        p
    }
}

/// a = (star color, spot activity), b = (stream brightness, jets, star seed, 0),
/// c = (jet color, disk outer radius), d/e/f = disk receding / approaching / core colors.
pub fn build(c: &WallpaperConfig, _t: f64, _cam: &Camera, _width: u32, _height: u32,
             _events: &EventSchedule, _demo: &DemoMap) -> SceneParamsGpu {
    let mut p = SceneParamsGpu::default();
    let star = c.tde_star.color();
    p.a = [star.r, star.g, star.b, c.tde_star.activity() as f32];
    p.b = [c.tde_stream_brightness as f32, if c.tde_jets { 1.0 } else { 0.0 }, 0.0, 0.0];
    p.c = v3w(c.tde_jet_color.light3(level::TDE_JET), TDE_DISK_OUTER as f32);
    let (rec, app, core) = match c.tde_disk_colors {
        TdeDiskColors::Palette => {
            let g = palette_gpu(c);
            (g.receding, g.approaching, g.core)
        }
        TdeDiskColors::Fiery => (rgb(1.0, 0.22, 0.03).simd(), rgb(1.0, 0.55, 0.12).simd(), rgb(1.0, 0.85, 0.5).simd()),
        TdeDiskColors::BlueWhite => (rgb(0.35, 0.5, 1.0).simd(), rgb(0.7, 0.85, 1.0).simd(), rgb(0.95, 0.97, 1.0).simd()),
    };
    p.d = rec;
    p.e = app;
    p.f = core;
    p
}

/// SceneParams.tidalDisruptionBake: the bake kernel's `T` uniforms.
pub fn bake_params(c: &WallpaperConfig) -> SceneParamsGpu {
    TdeGeometry::new(c).bake()
}
