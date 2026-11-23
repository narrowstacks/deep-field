//! The GPU side, after Rendering/Renderer.swift: pipelines, the one-time ray bake, per-frame
//! encoding, bloom, and the nearest-neighbor present pass.

use std::cell::RefCell;
use std::collections::HashMap;
use std::time::Instant;

use wgpu::util::DeviceExt;

use crate::camera::{Camera, SceneGeometry};
use crate::config::{BakeKey, SceneKind, WallpaperConfig};
use crate::events::EventSchedule;
use crate::gpu_types::*;
use crate::shader;

/// Bake texture slots, matching the shaders' binding numbers.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Slot {
    HitA = 0, HitB, Sky, Shell0P, Shell0D, Shell1P, Shell1D, Dir, Info, StarId,
}

pub const SLOTS: [Slot; 10] = [
    Slot::HitA, Slot::HitB, Slot::Sky, Slot::Shell0P, Slot::Shell0D,
    Slot::Shell1P, Slot::Shell1D, Slot::Dir, Slot::Info, Slot::StarId,
];

impl Slot {
    /// Each slot's texture format. Metal packs some lookups into 16-bit normalized formats;
    /// WebGPU can't write those from a compute shader, so they keep full floats here.
    fn format(self) -> wgpu::TextureFormat {
        use wgpu::TextureFormat as T;
        match self {
            Slot::Sky => T::Rgba16Float,
            Slot::Dir => T::Rg32Float,
            Slot::StarId => T::R32Uint,
            _ => T::Rgba32Float,
        }
    }
}

/// The frame textures (scene output before the upscale) are always this format.
pub const CELL_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
const HDR_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;

/// Static per-pixel lookups from a bake.
pub struct Baked {
    /// One per Slot; None where the scene doesn't use the slot (a placeholder is bound).
    textures: Vec<Option<wgpu::Texture>>,
    pub key: BakeKey,
    /// Whether planet orbit-shell crossings were recorded (lensed scenes with planets).
    pub shells: bool,
    /// The camera the rays were traced from, reused by frames drawn from this bake.
    pub camera: Camera,
    pub width: u32,
    pub height: u32,
    #[allow(dead_code)]
    pub bytes: u64,
}

impl Baked {
    /// Whether this bake still serves `c`, or it needs a new one.
    pub fn matches(&self, c: &WallpaperConfig) -> bool {
        self.key == c.bake_key() && self.shells == Renderer::needs_shells(c)
    }
}

struct BloomTargets {
    hdr: wgpu::Texture,
    /// Ping-pong pairs for the blur: quarter size, then each level half the one before.
    levels: Vec<(wgpu::Texture, wgpu::Texture)>,
}

pub struct Renderer {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub adapter_info: wgpu::AdapterInfo,
    pub instance: wgpu::Instance,
    pub adapter: wgpu::Adapter,
    start: Instant,

    bake_layout: wgpu::BindGroupLayout,
    sky_layout: wgpu::BindGroupLayout,
    frame_layout: wgpu::BindGroupLayout,
    bright_layout: wgpu::BindGroupLayout,
    down_layout: wgpu::BindGroupLayout,
    blur_layout: wgpu::BindGroupLayout,
    image_layout: wgpu::BindGroupLayout,
    present_layout: wgpu::BindGroupLayout,

    bake_pipelines: HashMap<&'static str, wgpu::ComputePipeline>,
    sky_pipeline: wgpu::ComputePipeline,
    bloom_bright: wgpu::ComputePipeline,
    bloom_down: wgpu::ComputePipeline,
    bloom_blur: wgpu::ComputePipeline,
    image_pipeline: wgpu::RenderPipeline,

    frame_module: wgpu::ShaderModule,
    frame_pipeline_layout: wgpu::PipelineLayout,
    frame_pipelines: RefCell<HashMap<(&'static str, wgpu::TextureFormat), wgpu::RenderPipeline>>,
    present_module: wgpu::ShaderModule,
    present_pipeline_layout: wgpu::PipelineLayout,
    present_pipelines: RefCell<HashMap<wgpu::TextureFormat, wgpu::RenderPipeline>>,

    /// Bound in place of the textures a scene doesn't use, one per slot format.
    placeholders: Vec<wgpu::Texture>,
    blue_noise: wgpu::Buffer,
    linear_clamp: wgpu::Sampler,
    bloom_targets: RefCell<HashMap<(u32, u32), BloomTargets>>,
}

fn tex_entry(binding: u32, vis: wgpu::ShaderStages, sample: wgpu::TextureSampleType) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: vis,
        ty: wgpu::BindingType::Texture {
            sample_type: sample,
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    }
}

fn storage_tex_entry(binding: u32, format: wgpu::TextureFormat) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::StorageTexture {
            access: wgpu::StorageTextureAccess::WriteOnly,
            format,
            view_dimension: wgpu::TextureViewDimension::D2,
        },
        count: None,
    }
}

fn buffer_entry(binding: u32, vis: wgpu::ShaderStages, storage: bool) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: vis,
        ty: wgpu::BindingType::Buffer {
            ty: if storage {
                wgpu::BufferBindingType::Storage { read_only: true }
            } else {
                wgpu::BufferBindingType::Uniform
            },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

fn sampler_entry(binding: u32, vis: wgpu::ShaderStages) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: vis,
        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
        count: None,
    }
}

const UNFILTERABLE: wgpu::TextureSampleType = wgpu::TextureSampleType::Float { filterable: false };
const FILTERABLE: wgpu::TextureSampleType = wgpu::TextureSampleType::Float { filterable: true };

fn v4(x: f64, y: f64, z: f64, w: f64) -> V4 {
    [x as f32, y as f32, z as f32, w as f32]
}

impl Renderer {
    /// Picks the high-performance GPU and compiles every pipeline. Shader errors are reported
    /// through naga first, so they name the WGSL file and line.
    pub fn new() -> Result<Renderer, String> {
        for (label, parts) in [("bake", shader::BAKE), ("frame", shader::FRAME), ("bloom", shader::BLOOM), ("present", shader::PRESENT)] {
            shader::validate(label, parts).map_err(|e| format!("shader module {label} failed to compile:\n{e}"))?;
        }
        trace("validated");
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::util::backend_bits_from_env().unwrap_or(wgpu::Backends::DX12),
            ..Default::default()
        });
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))
        .ok_or("no GPU adapter found")?;
        let adapter_info = adapter.get_info();
        trace(&format!("adapter {} {:?}", adapter_info.name, adapter_info.backend));
        // the bake writes eight storage textures in one dispatch, over WebGPU's default of four
        let mut limits = wgpu::Limits::default();
        let supported = adapter.limits();
        limits.max_storage_textures_per_shader_stage = supported.max_storage_textures_per_shader_stage.min(16);
        if limits.max_storage_textures_per_shader_stage < 8 {
            return Err(format!("{} supports only {} storage textures per stage (8 needed)",
                               adapter_info.name, limits.max_storage_textures_per_shader_stage));
        }
        limits.max_texture_dimension_2d = supported.max_texture_dimension_2d;
        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("deepfield"),
                // GPU timestamps for --benchmark, where the GPU has them
                required_features: adapter.features() & (wgpu::Features::TIMESTAMP_QUERY | wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS),
                required_limits: limits,
                memory_hints: wgpu::MemoryHints::Performance,
            },
            None,
        ))
        .map_err(|e| format!("could not open the GPU: {e}"))?;

        let module = |label: &str, parts| {
            device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some(label),
                source: wgpu::ShaderSource::Wgsl(shader::join(parts).into()),
            })
        };
        trace("device");
        let bake_module = module("bake", shader::BAKE);
        trace("bake module");
        let frame_module = module("frame", shader::FRAME);
        let bloom_module = module("bloom", shader::BLOOM);
        let present_module = module("present", shader::PRESENT);
        trace("modules");

        let cs = wgpu::ShaderStages::COMPUTE;
        let fs = wgpu::ShaderStages::FRAGMENT;
        let layout = |label: &str, entries: &[wgpu::BindGroupLayoutEntry]| {
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(label), entries })
        };

        let mut bake_entries: Vec<_> = [Slot::HitA, Slot::HitB, Slot::Shell0P, Slot::Shell0D, Slot::Shell1P, Slot::Shell1D, Slot::Dir, Slot::Info]
            .iter()
            .map(|s| storage_tex_entry(*s as u32, s.format()))
            .collect();
        bake_entries.push(buffer_entry(10, cs, false));
        bake_entries.push(buffer_entry(11, cs, false));
        let bake_layout = layout("bake", &bake_entries);
        let sky_layout = layout("sky", &[
            buffer_entry(10, cs, false),
            tex_entry(20, cs, UNFILTERABLE),
            tex_entry(21, cs, UNFILTERABLE),
            storage_tex_entry(22, Slot::Sky.format()),
            storage_tex_entry(23, Slot::StarId.format()),
        ]);
        let mut frame_entries: Vec<_> = SLOTS
            .iter()
            .map(|s| tex_entry(*s as u32, fs, if *s == Slot::StarId { wgpu::TextureSampleType::Uint } else { UNFILTERABLE }))
            .collect();
        for (b, storage) in [(10, false), (11, true), (12, false), (13, false), (14, true), (15, true), (16, false), (17, false), (18, true)] {
            frame_entries.push(buffer_entry(b, fs, storage));
        }
        frame_entries.push(sampler_entry(19, fs));
        let frame_layout = layout("frame", &frame_entries);
        let bright_layout = layout("bloomBright", &[buffer_entry(10, cs, false), tex_entry(30, cs, UNFILTERABLE), storage_tex_entry(31, HDR_FORMAT)]);
        let down_layout = layout("bloomDown", &[sampler_entry(19, cs), tex_entry(32, cs, FILTERABLE), storage_tex_entry(31, HDR_FORMAT)]);
        let blur_layout = layout("bloomBlur", &[sampler_entry(19, cs), tex_entry(32, cs, FILTERABLE), storage_tex_entry(31, HDR_FORMAT), buffer_entry(34, cs, false)]);
        let image_layout = layout("image", &[
            buffer_entry(10, fs, false), buffer_entry(18, fs, true), sampler_entry(19, fs),
            tex_entry(30, fs, UNFILTERABLE), tex_entry(33, fs, FILTERABLE),
        ]);
        let present_layout = layout("present", &[tex_entry(0, fs, UNFILTERABLE), buffer_entry(1, fs, false)]);

        let pipeline_layout = |l: &wgpu::BindGroupLayout| {
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[l], push_constant_ranges: &[] })
        };
        let compute = |m: &wgpu::ShaderModule, l: &wgpu::BindGroupLayout, entry: &str| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&pipeline_layout(l)),
                module: m,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        let mut bake_pipelines = HashMap::new();
        for entry in ["bakeBlackHole", "bakeWormhole", "bakeFlat"] {
            bake_pipelines.insert(entry, compute(&bake_module, &bake_layout, entry));
        }
        trace("bake pipelines");
        let sky_pipeline = compute(&bake_module, &sky_layout, "skyPass");
        let bloom_bright = compute(&bloom_module, &bright_layout, "bloomBright");
        let bloom_down = compute(&bloom_module, &down_layout, "bloomDown");
        let bloom_blur = compute(&bloom_module, &blur_layout, "bloomBlur");
        let image_pipeline = Self::render_pipeline(&device, &bloom_module, &pipeline_layout(&image_layout), "imageFragment", CELL_FORMAT);

        let placeholders = SLOTS
            .iter()
            .map(|s| {
                device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("placeholder"),
                    size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: s.format(),
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::STORAGE_BINDING,
                    view_formats: &[],
                })
            })
            .collect();
        let noise: Vec<u32> = crate::blue_noise::BLUE_NOISE_64.iter().map(|&v| v as u32).collect();
        let blue_noise = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("blueNoise64"),
            contents: bytemuck::cast_slice(&noise),
            usage: wgpu::BufferUsages::STORAGE,
        });
        let linear_clamp = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("linearClamp"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        Ok(Renderer {
            frame_pipeline_layout: pipeline_layout(&frame_layout),
            present_pipeline_layout: pipeline_layout(&present_layout),
            device,
            queue,
            adapter_info,
            instance,
            adapter,
            start: Instant::now(),
            bake_layout,
            sky_layout,
            frame_layout,
            bright_layout,
            down_layout,
            blur_layout,
            image_layout,
            present_layout,
            bake_pipelines,
            sky_pipeline,
            bloom_bright,
            bloom_down,
            bloom_blur,
            image_pipeline,
            frame_module,
            frame_pipelines: RefCell::new(HashMap::new()),
            present_module,
            present_pipelines: RefCell::new(HashMap::new()),
            placeholders,
            blue_noise,
            linear_clamp,
            bloom_targets: RefCell::new(HashMap::new()),
        })
    }

    /// Seconds since the renderer started (f64, so long orbital periods stay precise).
    pub fn elapsed(&self) -> f64 {
        self.start.elapsed().as_secs_f64()
    }

    fn render_pipeline(device: &wgpu::Device, module: &wgpu::ShaderModule, layout: &wgpu::PipelineLayout,
                       fragment: &str, format: wgpu::TextureFormat) -> wgpu::RenderPipeline {
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(fragment),
            layout: Some(layout),
            vertex: wgpu::VertexState {
                module,
                entry_point: Some("fullscreenVertex"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module,
                entry_point: Some(fragment),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState { format, blend: None, write_mask: wgpu::ColorWrites::ALL })],
            }),
            multiview: None,
            cache: None,
        })
    }

    /// Each scene's fragment function.
    fn fragment_name(scene: SceneKind) -> &'static str {
        match scene {
            SceneKind::BlackHole | SceneKind::Wormhole => "lensedFragment",
            SceneKind::TidalDisruption => "tdeFragment",
            SceneKind::Binary | SceneKind::Trinary => "systemFragment",
            SceneKind::StellarSurface => "stellarFragment",
            SceneKind::GasGiant => "gasGiantFragment",
            SceneKind::Galaxy => "galaxyFragment",
            SceneKind::Pulsar => "pulsarFragment",
            SceneKind::Nebula => "nebulaFragment",
            SceneKind::Comet => "cometFragment",
            SceneKind::PlanetaryNebula => "planetaryFragment",
            SceneKind::RingedPlanet => "ringedFragment",
            SceneKind::AuroraOrbit => "auroraFragment",
            SceneKind::LiveEarth => "liveEarthFragment",
            SceneKind::ProtoplanetaryDisk => "protoDiskFragment",
            SceneKind::NeutronMerger => "neutronMergerFragment",
            SceneKind::BlackHoleMerger => "blackHoleMergerFragment",
            SceneKind::DysonSwarm => "dysonFragment",
            SceneKind::RoguePlanet => "rogueFragment",
            SceneKind::Eclipse => "eclipseFragment",
            SceneKind::Quasar => "quasarFragment",
        }
    }

    fn frame_pipeline(&self, scene: SceneKind, format: wgpu::TextureFormat) -> std::cell::Ref<'_, wgpu::RenderPipeline> {
        let name = Self::fragment_name(scene);
        if !self.frame_pipelines.borrow().contains_key(&(name, format)) {
            let p = Self::render_pipeline(&self.device, &self.frame_module, &self.frame_pipeline_layout, name, format);
            self.frame_pipelines.borrow_mut().insert((name, format), p);
        }
        std::cell::Ref::map(self.frame_pipelines.borrow(), |m| &m[&(name, format)])
    }

    /// How a scene bends light: 0 not at all, 1 black hole (with a shadow), 2 wormhole.
    pub fn lensing(scene: SceneKind) -> f32 {
        match scene {
            SceneKind::BlackHole | SceneKind::TidalDisruption => 1.0,
            SceneKind::Wormhole => 2.0,
            _ => 0.0,
        }
    }

    /// Lensed scenes find their planets through the baked orbit-shell crossings.
    pub fn needs_shells(c: &WallpaperConfig) -> bool {
        Self::lensing(c.scene) > 0.0 && c.scene.has_planets() && c.planet_count > 0
    }

    /// Which slots a config's bake allocates (the rest get the placeholder).
    fn allocated(c: &WallpaperConfig) -> [bool; 10] {
        let lens = Self::lensing(c.scene);
        let shells = Self::needs_shells(c);
        let tde = c.scene == SceneKind::TidalDisruption;
        SLOTS.map(|s| match s {
            Slot::HitA | Slot::HitB => lens == 1.0,
            Slot::Sky | Slot::Dir | Slot::StarId => true,
            Slot::Shell0P | Slot::Shell1P => shells || tde,
            Slot::Shell0D | Slot::Shell1D => shells,
            Slot::Info => lens > 0.0,
        })
    }

    fn bake_entry(c: &WallpaperConfig) -> &'static str {
        match Self::lensing(c.scene) as i32 {
            1 => "bakeBlackHole",
            2 => "bakeWormhole",
            _ => "bakeFlat",
        }
    }

    /// Trace every pixel's light ray once, then the sky pass. Reruns only when the size or a
    /// bake-affecting setting changes; textures of `old` are reused where the size matches.
    pub fn bake(&self, w: u32, h: u32, c: &WallpaperConfig, old: Option<Baked>) -> Baked {
        let allocated = Self::allocated(c);
        let mut old_textures = old.map(|b| (b.width, b.height, b.textures));
        let mut textures: Vec<Option<wgpu::Texture>> = Vec::new();
        let mut bytes = 0u64;
        for (i, s) in SLOTS.iter().enumerate() {
            if !allocated[i] {
                textures.push(None);
                continue;
            }
            let reuse = match &mut old_textures {
                Some((ow, oh, t)) if *ow == w && *oh == h => t[i].take(),
                _ => None,
            };
            let t = reuse.unwrap_or_else(|| {
                self.device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("bake"),
                    size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: s.format(),
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::STORAGE_BINDING,
                    view_formats: &[],
                })
            });
            bytes += w as u64 * h as u64 * s.format().block_copy_size(None).unwrap_or(4) as u64;
            textures.push(Some(t));
        }
        let shells = Self::needs_shells(c);
        let cam = Camera::new(c, w as f64 / h as f64);
        let p = BakeParams {
            width: w as f32,
            height: h as f32,
            cam_dist: cam.distance as f32,
            cam_elev: (c.camera_tilt() / 180.0 * std::f64::consts::PI) as f32,
            tan_half_fov: cam.tan_half as f32,
            disk_in: SceneGeometry::DISK_IN,
            disk_out: if c.scene == SceneKind::TidalDisruption { (crate::scene_params::TDE_DISK_OUTER * 1.2) as f32 } else { c.disk_size as f32 },
            roll: SceneGeometry::ROLL as f32,
            shell_r0: SceneGeometry::shell_radii()[0],
            shell_r1: SceneGeometry::shell_radii()[1],
            throat: c.throat as f32,
            star_density: c.star_density as f32,
            lensing: Self::lensing(c.scene),
            galaxies: c.galaxies as i32 as f32,
            look_x: cam.look.x as f32,
            look_y: cam.look.y as f32,
            milky_way: c.milky_way as i32 as f32,
            nebula_type: 0.0,
            nebula_seed: 0.0,
            shells: shells as i32 as f32,
            sky_seed: (c.sky_seed % 1_000_000) as f32,
            pad: [0.0; 3],
        };
        let pbuf = self.uniform(bytemuck::bytes_of(&p));
        let tde = if c.scene == SceneKind::TidalDisruption {
            crate::scenes::tidal_disruption::bake_params(c)
        } else {
            SceneParamsGpu::default()
        };
        let tbuf = self.uniform(bytemuck::bytes_of(&tde));
        let views: Vec<wgpu::TextureView> = (0..SLOTS.len())
            .map(|i| textures[i].as_ref().unwrap_or(&self.placeholders[i]).create_view(&Default::default()))
            .collect();

        let mut entries: Vec<wgpu::BindGroupEntry> = [Slot::HitA, Slot::HitB, Slot::Shell0P, Slot::Shell0D, Slot::Shell1P, Slot::Shell1D, Slot::Dir, Slot::Info]
            .iter()
            .map(|s| wgpu::BindGroupEntry { binding: *s as u32, resource: wgpu::BindingResource::TextureView(&views[*s as usize]) })
            .collect();
        entries.push(wgpu::BindGroupEntry { binding: 10, resource: pbuf.as_entire_binding() });
        entries.push(wgpu::BindGroupEntry { binding: 11, resource: tbuf.as_entire_binding() });
        let bake_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some("bake"), layout: &self.bake_layout, entries: &entries });
        let sky_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("sky"),
            layout: &self.sky_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 10, resource: pbuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 20, resource: wgpu::BindingResource::TextureView(&views[Slot::Dir as usize]) },
                wgpu::BindGroupEntry { binding: 21, resource: wgpu::BindingResource::TextureView(&views[Slot::Info as usize]) },
                wgpu::BindGroupEntry { binding: 22, resource: wgpu::BindingResource::TextureView(&views[Slot::Sky as usize]) },
                wgpu::BindGroupEntry { binding: 23, resource: wgpu::BindingResource::TextureView(&views[Slot::StarId as usize]) },
            ],
        });
        let mut enc = self.device.create_command_encoder(&Default::default());
        {
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("bake"), timestamp_writes: None });
            pass.set_pipeline(&self.bake_pipelines[Self::bake_entry(c)]);
            pass.set_bind_group(0, &bake_group, &[]);
            pass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        {
            // a second pass, so it sees the finished ray bake: sky lookups, filtered by how much
            // lensing squeezes the sky into each pixel
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("sky"), timestamp_writes: None });
            pass.set_pipeline(&self.sky_pipeline);
            pass.set_bind_group(0, &sky_group, &[]);
            pass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        self.queue.submit([enc.finish()]);
        Baked { textures, key: c.bake_key(), shells, camera: cam, width: w, height: h, bytes }
    }

    fn uniform(&self, bytes: &[u8]) -> wgpu::Buffer {
        self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: bytes, usage: wgpu::BufferUsages::UNIFORM })
    }

    fn storage<T: bytemuck::Pod + Default>(&self, items: &[T]) -> wgpu::Buffer {
        // a binding needs at least one element
        let one = [T::default()];
        let data: &[T] = if items.is_empty() { &one } else { items };
        self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: bytemuck::cast_slice(data), usage: wgpu::BufferUsages::STORAGE })
    }

    pub fn make_target(&self, w: u32, h: u32, extra: wgpu::TextureUsages) -> wgpu::Texture {
        self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("cells"),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: CELL_FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING | extra,
            view_formats: &[],
        })
    }

    /// Encodes one frame of the scene into `target` (CELL_FORMAT, the shaded size). With bloom
    /// on, the scene renders its linear light to a float texture and the bloom passes and the
    /// final tone map and dither (imageFragment) follow; with it off the scene pass finishes the
    /// image itself.
    pub fn encode_frame(&self, enc: &mut wgpu::CommandEncoder, target: &wgpu::Texture, baked: &Baked, elapsed: f64,
                        c: &WallpaperConfig, events: &EventSchedule, demo: &HashMap<u64, f64>) {
        let (tw, th) = (target.width(), target.height());
        let bloom_amount = c.bloom + c.scene.extra_bloom();
        let bloom = bloom_amount > 0.0;
        if bloom {
            self.ensure_bloom_targets(tw, th);
        }
        let aspect = tw as f64 / th as f64;
        let cam = if baked.camera.aspect == aspect { baked.camera.clone() } else { Camera::new(c, aspect) };
        let planets = crate::planets::planets_gpu(c, elapsed);
        let stars = crate::star_system::stars(c, elapsed);
        let lights = crate::star_system::lights(c, &stars);
        // a lensed scene baked without shells can't show planets (until the rebake catches up)
        let planet_count = if Self::lensing(c.scene) > 0.0 && !baked.shells { 0 } else { planets.len() };

        let wrap = SceneGeometry::FLOW_PERIOD as f64 * 1000.0; // disk animation is periodic in flowPeriod
        let pixel_angle = 2.0 * cam.tan_half / th as f64;
        let mut f = FrameParams {
            time: (elapsed % wrap) as f32,
            levels: c.levels as f32,
            disk_in: SceneGeometry::DISK_IN,
            disk_out: c.disk_size as f32,
            exposure: c.brightness as f32,
            disk_speed: (1.6 * c.disk_speed) as f32,
            flow_period: SceneGeometry::FLOW_PERIOD,
            planet_count: planet_count as f32,
            shell_r0: SceneGeometry::shell_radii()[0],
            shell_r1: SceneGeometry::shell_radii()[1],
            saturation: c.saturation as f32,
            scene: c.scene.shader_index(),
            dither: c.dither.shader_index(),
            twinkle: c.twinkles.rate() as f32,
            pulsars: c.pulsars as i32 as f32,
            sky_brightness: c.nebula as f32,
            pixel_angle: pixel_angle as f32,
            star_count: stars.len() as f32,
            light_count: lights.len() as f32,
            ring_strength: c.photon_ring as f32,
            nebula_type: 0.0,
            screen_scale: cam.screen_scale as f32,
            twinkle_brightness: c.twinkle_brightness as f32,
            twinkle_speed: c.twinkle_speed as f32,
            cam_pos: v4(cam.pos.x, cam.pos.y, cam.pos.z, 0.0),
            cam_right: v4(cam.right.x, cam.right.y, cam.right.z, tw as f64),
            cam_up: v4(cam.up.x, cam.up.y, cam.up.z, th as f64),
            image: v4(c.contrast, c.black_point, c.highlights, c.vignette),
            bloom: v4(bloom_amount, c.bloom_threshold, if bloom { 1.0 } else { 0.0 }, c.bloom_radius),
        };
        let palette = crate::palette::palette_gpu(c);
        let ev = events.gpu(elapsed, c, &cam, th);
        let galaxy = if c.scene == SceneKind::Galaxy { crate::scenes::galaxy::galaxy_gpu(c, elapsed) } else { GalaxyGpu::default() };
        let scene = crate::scene_params::build(c, elapsed, &cam, tw, th, events, demo);

        let fbuf = self.uniform(bytemuck::bytes_of(&f));
        let pbuf = self.storage(&planets);
        let ebuf = self.uniform(bytemuck::bytes_of(&ev));
        let palbuf = self.uniform(bytemuck::bytes_of(&palette));
        let sbuf = self.storage(&stars);
        let lbuf = self.storage(&lights);
        let gbuf = self.uniform(bytemuck::bytes_of(&galaxy));
        let scbuf = self.uniform(bytemuck::bytes_of(&scene));
        let views: Vec<wgpu::TextureView> = (0..SLOTS.len())
            .map(|i| baked.textures[i].as_ref().unwrap_or(&self.placeholders[i]).create_view(&Default::default()))
            .collect();
        let mut entries: Vec<wgpu::BindGroupEntry> = (0..SLOTS.len())
            .map(|i| wgpu::BindGroupEntry { binding: i as u32, resource: wgpu::BindingResource::TextureView(&views[i]) })
            .collect();
        for (b, buf) in [(10, &fbuf), (11, &pbuf), (12, &ebuf), (13, &palbuf), (14, &sbuf), (15, &lbuf), (16, &gbuf), (17, &scbuf), (18, &self.blue_noise)] {
            entries.push(wgpu::BindGroupEntry { binding: b, resource: buf.as_entire_binding() });
        }
        entries.push(wgpu::BindGroupEntry { binding: 19, resource: wgpu::BindingResource::Sampler(&self.linear_clamp) });
        let group = self.device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some("frame"), layout: &self.frame_layout, entries: &entries });

        let targets = self.bloom_targets.borrow();
        let bloom_targets = if bloom { targets.get(&(tw, th)) } else { None };
        let scene_view = match bloom_targets {
            Some(b) => b.hdr.create_view(&Default::default()),
            None => target.create_view(&Default::default()),
        };
        {
            let pipeline = self.frame_pipeline(c.scene, if bloom_targets.is_some() { HDR_FORMAT } else { CELL_FORMAT });
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("scene"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &scene_view,
                    resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.draw(0..3, 0..1);
        }
        if let Some(b) = bloom_targets {
            self.encode_bloom(enc, b, target, &mut f, &fbuf);
        }
    }

    fn ensure_bloom_targets(&self, w: u32, h: u32) {
        let mut targets = self.bloom_targets.borrow_mut();
        if targets.contains_key(&(w, h)) {
            return;
        }
        let make = |w: u32, h: u32, usage: wgpu::TextureUsages| {
            self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("bloom"),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: HDR_FORMAT,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | usage,
                view_formats: &[],
            })
        };
        let hdr = make(w, h, wgpu::TextureUsages::RENDER_ATTACHMENT);
        // enough levels for the widest radius on a 6K display (sigma ~100 quarter texels)
        let mut levels = Vec::new();
        let (mut lw, mut lh) = ((w + 3) / 4, (h + 3) / 4);
        lw = lw.max(1);
        lh = lh.max(1);
        while levels.len() < 7 {
            levels.push((make(lw, lh, wgpu::TextureUsages::STORAGE_BINDING), make(lw, lh, wgpu::TextureUsages::STORAGE_BINDING)));
            if lw.min(lh) < 8 {
                break;
            }
            lw = (lw + 1) / 2;
            lh = (lh + 1) / 2;
        }
        if targets.len() >= 6 {
            targets.clear(); // sizes come and go (previews, exports)
        }
        targets.insert((w, h), BloomTargets { hdr, levels });
    }

    /// Bright pass into a quarter-size texture, halved until the glow's sigma is 3 texels or
    /// less, a horizontal and a vertical blur there, then the composite that adds the glow and
    /// tone maps, quantizes and dithers into `target`.
    fn encode_bloom(&self, enc: &mut wgpu::CommandEncoder, t: &BloomTargets, target: &wgpu::Texture, f: &mut FrameParams, fbuf: &wgpu::Buffer) {
        let view = |tex: &wgpu::Texture| tex.create_view(&Default::default());
        let dispatch = |enc: &mut wgpu::CommandEncoder, pipeline: &wgpu::ComputePipeline, group: &wgpu::BindGroup, out: &wgpu::Texture| {
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("bloom"), timestamp_writes: None });
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, group, &[]);
            pass.dispatch_workgroups(out.width().div_ceil(8), out.height().div_ceil(8), 1);
        };
        let hdr_view = view(&t.hdr);
        let l0 = view(&t.levels[0].0);
        let bright = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("bloomBright"),
            layout: &self.bright_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 10, resource: fbuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 30, resource: wgpu::BindingResource::TextureView(&hdr_view) },
                wgpu::BindGroupEntry { binding: 31, resource: wgpu::BindingResource::TextureView(&l0) },
            ],
        });
        dispatch(enc, &self.bloom_bright, &bright, &t.levels[0].0);
        // the radius is a fraction of the frame's shorter side, so the glow looks the same at any size
        let l0t = &t.levels[0].0;
        let mut sigma = f.bloom[3] * l0t.width().min(l0t.height()) as f32;
        let mut k = 0;
        while sigma > 3.0 && k + 1 < t.levels.len() {
            let (src, dst) = (view(&t.levels[k].0), view(&t.levels[k + 1].0));
            let g = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("bloomDown"),
                layout: &self.down_layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 19, resource: wgpu::BindingResource::Sampler(&self.linear_clamp) },
                    wgpu::BindGroupEntry { binding: 32, resource: wgpu::BindingResource::TextureView(&src) },
                    wgpu::BindGroupEntry { binding: 31, resource: wgpu::BindingResource::TextureView(&dst) },
                ],
            });
            dispatch(enc, &self.bloom_down, &g, &t.levels[k + 1].0);
            k += 1;
            sigma /= 2.0;
        }
        // the 4x4 means already spread the light by about 0.4 texel squared at this level
        if k > 0 {
            sigma = (sigma * sigma - 0.4).max(0.25).sqrt();
        }
        let (a, b) = &t.levels[k];
        for (src, dst, dir) in [(a, b, [1.0f32, 0.0]), (b, a, [0.0, 1.0])] {
            let params: V4 = [dir[0], dir[1], sigma, 0.0];
            let pb = self.uniform(bytemuck::bytes_of(&params));
            let (sv, dv) = (view(src), view(dst));
            let g = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("bloomBlur"),
                layout: &self.blur_layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 19, resource: wgpu::BindingResource::Sampler(&self.linear_clamp) },
                    wgpu::BindGroupEntry { binding: 32, resource: wgpu::BindingResource::TextureView(&sv) },
                    wgpu::BindGroupEntry { binding: 31, resource: wgpu::BindingResource::TextureView(&dv) },
                    wgpu::BindGroupEntry { binding: 34, resource: pb.as_entire_binding() },
                ],
            });
            dispatch(enc, &self.bloom_blur, &g, dst);
        }

        f.bloom[2] = 0.0;
        f.bloom[3] = 1.0 / (4u32 << k) as f32; // frame pixels to glow texels, for imageFragment
        let fb = self.uniform(bytemuck::bytes_of(f));
        let glow_view = view(a);
        let g = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("image"),
            layout: &self.image_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 10, resource: fb.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 18, resource: self.blue_noise.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 19, resource: wgpu::BindingResource::Sampler(&self.linear_clamp) },
                wgpu::BindGroupEntry { binding: 30, resource: wgpu::BindingResource::TextureView(&hdr_view) },
                wgpu::BindGroupEntry { binding: 33, resource: wgpu::BindingResource::TextureView(&glow_view) },
            ],
        });
        let target_view = view(target);
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("image"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &target_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        pass.set_pipeline(&self.image_pipeline);
        pass.set_bind_group(0, &g, &[]);
        pass.draw(0..3, 0..1);
    }

    /// Scales a finished frame of cells onto a screen-sized target with nearest-neighbor
    /// filtering. `cell` is screen pixels per cell; the frame is centered if it overhangs.
    pub fn encode_present(&self, enc: &mut wgpu::CommandEncoder, cells: &wgpu::Texture, target: &wgpu::TextureView,
                          format: wgpu::TextureFormat, screen: (u32, u32), cell: u32) {
        if !self.present_pipelines.borrow().contains_key(&format) {
            let p = Self::render_pipeline(&self.device, &self.present_module, &self.present_pipeline_layout, "presentFragment", format);
            self.present_pipelines.borrow_mut().insert(format, p);
        }
        let pipelines = self.present_pipelines.borrow();
        let ox = (cells.width() * cell).saturating_sub(screen.0) as f32 / 2.0 / cell as f32;
        let oy = (cells.height() * cell).saturating_sub(screen.1) as f32 / 2.0 / cell as f32;
        let scale: V4 = [cell as f32, cell as f32, ox, oy];
        let sb = self.uniform(bytemuck::bytes_of(&scale));
        let cv = cells.create_view(&Default::default());
        let g = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("present"),
            layout: &self.present_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&cv) },
                wgpu::BindGroupEntry { binding: 1, resource: sb.as_entire_binding() },
            ],
        });
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("present"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        pass.set_pipeline(&pipelines[&format]);
        pass.set_bind_group(0, &g, &[]);
        pass.draw(0..3, 0..1);
    }

    /// Reads a CELL_FORMAT texture back as tightly packed RGBA8 rows.
    pub fn read_rgba(&self, tex: &wgpu::Texture) -> Vec<u8> {
        let (w, h) = (tex.width(), tex.height());
        let row = w * 4;
        let padded = row.div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: (padded * h) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut enc = self.device.create_command_encoder(&Default::default());
        enc.copy_texture_to_buffer(
            wgpu::ImageCopyTexture { texture: tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::ImageCopyBuffer { buffer: &buf, layout: wgpu::ImageDataLayout { offset: 0, bytes_per_row: Some(padded), rows_per_image: None } },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        self.queue.submit([enc.finish()]);
        let slice = buf.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        self.device.poll(wgpu::Maintain::Wait);
        let data = slice.get_mapped_range();
        let mut out = Vec::with_capacity((row * h) as usize);
        for y in 0..h as usize {
            out.extend_from_slice(&data[y * padded as usize..y * padded as usize + row as usize]);
        }
        out
    }
}

/// Startup progress on stderr when DEEPFIELD_TRACE is set.
fn trace(what: &str) {
    if std::env::var_os("DEEPFIELD_TRACE").is_some() {
        eprintln!("deepfield: {what}");
    }
}
