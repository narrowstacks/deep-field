//! Uniform layouts shared with the shaders. Each struct mirrors the one of the same name in
//! shaders/common.wgsl field for field (and Rendering/GPUTypes.swift in the macOS app).

use bytemuck::{Pod, Zeroable};

pub type V4 = [f32; 4];

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct BakeParams {
    pub width: f32, pub height: f32, pub cam_dist: f32, pub cam_elev: f32,
    pub tan_half_fov: f32, pub disk_in: f32, pub disk_out: f32, pub roll: f32,
    pub shell_r0: f32, pub shell_r1: f32, pub throat: f32, pub star_density: f32,
    pub lensing: f32, pub galaxies: f32, pub look_x: f32, pub look_y: f32,
    pub milky_way: f32, pub nebula_type: f32, pub nebula_seed: f32, pub shells: f32,
    pub sky_seed: f32,
    pub pad: [f32; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct FrameParams {
    pub time: f32, pub levels: f32, pub disk_in: f32, pub disk_out: f32,
    pub exposure: f32, pub disk_speed: f32, pub flow_period: f32, pub planet_count: f32,
    pub shell_r0: f32, pub shell_r1: f32, pub saturation: f32, pub scene: f32,
    pub dither: f32, pub twinkle: f32, pub pulsars: f32, pub sky_brightness: f32,
    pub pixel_angle: f32, pub star_count: f32, pub light_count: f32, pub ring_strength: f32,
    pub nebula_type: f32,
    /// screen-space scenes' units per half screen height (1 on the desktop)
    pub screen_scale: f32,
    pub twinkle_brightness: f32, pub twinkle_speed: f32,
    pub cam_pos: V4,
    /// w = drawable width
    pub cam_right: V4,
    /// w = drawable height
    pub cam_up: V4,
    /// contrast, black point, highlight rolloff, vignette
    pub image: V4,
    /// amount, threshold, linear output (1 = scene pass for bloom), radius
    pub bloom: V4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct PaletteGpu {
    pub receding: V4, pub approaching: V4, pub core: V4, pub ring: V4,
    pub nebula_a: V4, pub nebula_b: V4, pub far_a: V4, pub far_b: V4,
    pub star_warm: V4, pub star_cool: V4, pub galaxy: V4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct PlanetGpu {
    /// xyz, w = shell index
    pub center: V4,
    /// rgb, w = radius
    pub color_a: V4,
    /// rgb, w = noise seed
    pub color_b: V4,
    /// spin angle, band frequency, atmosphere
    pub misc: V4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct StarGpu {
    /// xyz, w = radius
    pub pos: V4,
    /// rgb, w = glow scale
    pub color: V4,
    /// spin angle, seed, spot activity
    pub misc: V4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct LightGpu {
    /// xyz, w = intensity
    pub pos: V4,
    pub color: V4,
}

/// Occasional phenomena, scheduled on the CPU (see events.rs).
#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct EventsGpu {
    pub sn_dir: V4,
    pub sn_params: V4,
    pub comet_head: V4,
    pub comet_tail: V4,
    pub far_sn: V4,
    pub far_sn_params: V4,
    pub flare: V4,
    pub obj: V4,
    pub obj_dir: V4,
    pub throat: V4,
}

impl Default for EventsGpu {
    fn default() -> Self {
        EventsGpu {
            sn_dir: [0.0, 0.0, 1.0, 0.0],
            sn_params: [0.0; 4],
            comet_head: [0.0, 0.0, 1.0, 0.0],
            comet_tail: [0.0, 0.0, 1.0, 0.001],
            far_sn: [0.0, 0.0, 1.0, 0.0],
            far_sn_params: [0.0; 4],
            flare: [0.0; 4],
            obj: [0.0; 4],
            obj_dir: [1.0, 0.0, 1.0, 0.0],
            throat: [0.0; 4],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct GalaxyGpu {
    pub shape: V4,
    pub motion: V4,
    pub core: V4,
    pub arms: V4,
    pub nebula: V4,
    pub dust: V4,
    pub misc: V4,
}

/// Per-scene uniforms for the scenes built in scene_params.rs; each fragment shader reads these
/// slots its own way.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct SceneParamsGpu {
    pub a: V4, pub b: V4, pub c: V4, pub d: V4,
    pub e: V4, pub f: V4, pub g: V4, pub h: V4,
    pub i: V4, pub j: V4, pub k: V4, pub l: V4,
    pub m: V4, pub n: V4, pub o: V4, pub p: V4,
}

/// One of the real planets for scenes that draw the real sky (SkyPlanet in sky_planets.wgsl,
/// SkyPlanetGPU in the macOS app).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct SkyPlanetGpu {
    /// direction, w = true angular radius (rad)
    pub dir: V4,
    /// rgb, w = brightness (the stars' magnitude scale)
    pub color: V4,
    /// toward the sun from the planet, w = label shows (0/1)
    pub light: V4,
    /// north pole, w = which planet (0 Mercury ... 6 Neptune)
    pub pole: V4,
}
