//! Command-line rendering: snapshots and the benchmark (after Dev/Snapshot.swift,
//! Rendering/FrameCapture.swift and Dev/Benchmark.swift).

use std::collections::HashMap;
use std::time::Instant;

use crate::config::{SceneKind, WallpaperConfig};
use crate::events::EventSchedule;
use crate::renderer::Renderer;
use crate::transition::TransitionStyle;

struct Opts {
    snapshot: Option<String>,
    benchmark: bool,
    scene: Option<SceneKind>,
    size: (u32, u32),
    time: f64,
    config: Option<String>,
    events: bool,
    /// every `--demo` given, checked against the scene once the config is known
    demo_specs: Vec<String>,
    /// `--preset NAME|FILE`: a saved preset, palette, scene color preset or .deepfield file
    preset: Option<String>,
    /// `--transition-from SCENE:PROGRESS[:STYLE]`: a frame partway through a schedule transition
    transition_from: Option<String>,
    demo: HashMap<u64, f64>,
    frames: u32,
    /// Live Earth renders read the last fetched cloud and aurora maps instead of the bundled ones.
    live_earth_cache: bool,
    /// `--prefetch-history SECONDS`: fetch a span's real past clouds and exit.
    prefetch_history: Option<f64>,
    fetch_live_earth: bool,
}

fn parse(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts {
        snapshot: None, benchmark: false, scene: None, size: (1720, 720), time: 300.0,
        config: None, events: true, demo_specs: vec![], preset: None, transition_from: None, demo: HashMap::new(), frames: 120,
        live_earth_cache: false, prefetch_history: None, fetch_live_earth: false,
    };
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut val = |name: &str| it.next().cloned().ok_or(format!("usage: {name} needs a value"));
        match a.as_str() {
            "--snapshot" => o.snapshot = Some(val("--snapshot")?),
            "--benchmark" => o.benchmark = true,
            "--scene" => {
                let s = val("--scene")?;
                o.scene = Some(SceneKind::all().iter().copied().find(|k| k.raw() == s)
                    .ok_or(format!("unknown scene {s} (see --list-scenes)"))?);
            }
            "--size" => {
                let s = val("--size")?;
                let (w, h) = s.split_once('x').ok_or("usage: --size WxH")?;
                o.size = (w.parse().map_err(|_| "bad --size")?, h.parse().map_err(|_| "bad --size")?);
            }
            "--time" => o.time = val("--time")?.parse().map_err(|_| "bad --time")?,
            "--frames" => o.frames = val("--frames")?.parse().map_err(|_| "bad --frames")?,
            "--config" => o.config = Some(val("--config")?),
            "--defaults" => o.config = None,
            "--no-events" => o.events = false,
            "--live-earth-cache" => o.live_earth_cache = true,
            "--fetch-live-earth" => o.fetch_live_earth = true,
            "--prefetch-history" => o.prefetch_history = Some(val("--prefetch-history")?.parse().map_err(|_| "bad --prefetch-history")?),
            "--earth-timelapse" => crate::scenes::live_earth::set_time_lapse(val("--earth-timelapse")?.parse().map_err(|_| "bad --earth-timelapse")?),
            "--demo" => o.demo_specs.push(val("--demo")?),
            "--preset" => o.preset = Some(val("--preset")?),
            "--transition-from" => o.transition_from = Some(val("--transition-from")?),
            other => return Err(format!("usage: unknown option {other}")),
        }
    }
    Ok(o)
}

/// The config to render, and in `o.demo` the events started with `--demo` (checked against the
/// scene, so they wait until every option that can change it is in).
fn config(o: &mut Opts) -> Result<WallpaperConfig, String> {
    let mut c = match &o.config {
        Some(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
            // leniently, as the app loads its settings, so a config from another version reads
            WallpaperConfig::decode(&text).ok_or(format!("{path}: not a Deep Field config"))?
        }
        None => WallpaperConfig::default(),
    };
    if let Some(s) = o.scene {
        // as the Mac's `c.scene = ...` does, bringing in the scene's own tilt and image settings
        c.set_scene(s);
    }
    if let Some(p) = &o.preset {
        apply_preset(p, &mut c)?;
    }
    if !c.scene.is_ported() {
        // still rendered, so a scene can be checked while it's being ported
        eprintln!("deepfield: note: the {} scene isn't marked as ported yet", c.scene.raw());
    }
    o.demo = crate::events::demo_events(&o.demo_specs, c.scene)?;
    Ok(c)
}

/// Presets by name (PresetLookup in the Mac's ConfigKeys.swift): the user's saved presets first,
/// then the palette presets, then the scene's own color presets; or a `.deepfield` file.
fn apply_preset(name: &str, c: &mut WallpaperConfig) -> Result<(), String> {
    use crate::presets::{read_file, PresetStore, FILE_EXTENSION};
    let lower = name.to_lowercase();
    if lower.ends_with(&format!(".{FILE_EXTENSION}")) || lower.ends_with(".json") || std::path::Path::new(name).is_file() {
        *c = read_file(std::path::Path::new(name))?.applied(c);
        return Ok(());
    }
    if let Some(p) = PresetStore::load().named(name) {
        *c = p.applied(c);
        return Ok(());
    }
    if let Some((_, p)) = crate::palette::PaletteConfig::presets().into_iter().find(|(n, _)| n.eq_ignore_ascii_case(name)) {
        c.palette = p;
        return Ok(());
    }
    if let Some(p) = crate::color_presets::color_presets(c.scene).into_iter().find(|p| p.name.eq_ignore_ascii_case(name)) {
        p.apply(c);
        return Ok(());
    }
    Err(format!("no preset called \u{201C}{name}\u{201D}"))
}

pub fn run_cli(args: &[String]) -> Result<(), String> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print!("{}", crate::usage());
        return Ok(());
    }
    if args.iter().any(|a| a == "--check-shaders") {
        return if crate::shader::check() { Ok(()) } else { Err("shader validation failed".into()) };
    }
    if args.iter().any(|a| a == "--quit") {
        return if crate::wallpaper::quit_running() { Ok(()) } else { Err("Deep Field isn't running".into()) };
    }
    if args.iter().any(|a| a == "--list-scenes") {
        for s in SceneKind::all() {
            println!("{:<20} {}{}", s.raw(), s.title(), if s.is_ported() { "" } else { "  (not ported yet)" });
        }
        return Ok(());
    }
    let mut o = parse(args)?;
    if o.fetch_live_earth {
        return if crate::live_earth_feeds::fetch_now() { Ok(()) } else { Err("a Live Earth feed failed".into()) };
    }
    let c = config(&mut o)?;
    if let Some(span) = o.prefetch_history {
        // fetch a span's real clouds (from the config's frozen moment) before rendering it
        let start = crate::scenes::live_earth::date(&c, 0.0);
        let home = crate::astronomy::point(c.home_latitude, c.home_longitude);
        let now = crate::scenes::live_earth::now();
        let Some(source) = crate::historical_clouds::source(start, home, c.earth_distance, now) else {
            return Err("no past clouds for that moment".into());
        };
        crate::historical_clouds::prefetch(start, span, source);
        return Ok(());
    }
    let r = Renderer::new()?;
    // Live Earth renders never fetch, and read the bundled cloud and aurora maps so they come
    // out the same every time (or the last fetched ones with --live-earth-cache); a past moment
    // waits for that day's clouds, which don't change, so it stays deterministic.
    r.earth.feeds.allow_network.set(false);
    r.earth.feeds.use_cache.set(o.live_earth_cache);
    r.earth.history.blocking.set(true);
    if let Some(path) = &o.snapshot {
        let transition = o.transition_from.as_deref().map(|s| transition_from(s, &c)).transpose()?;
        let img = snapshot(&r, &c, o.size, o.time, o.events, &o.demo, transition.as_ref());
        write_png(path, o.size.0, o.size.1, &img)?;
        return Ok(());
    }
    if o.benchmark {
        return benchmark(&r, &c, o.size, o.frames);
    }
    Err("usage: nothing to do".into())
}

/// One frame at the shaded size (screen size / pixel size), as RGBA8 rows. Deterministic for a
/// given config, size and time: events use seed 1, like the macOS snapshots.
pub fn render_cells(r: &Renderer, c: &WallpaperConfig, w: u32, h: u32, time: f64, events_enabled: bool,
                    demo: &HashMap<u64, f64>) -> Vec<u8> {
    let baked = r.bake(w, h, c, None);
    let target = r.make_target(w, h, wgpu::TextureUsages::COPY_SRC);
    let mut events = EventSchedule::new(1);
    events.enabled = events_enabled;
    events.demo = demo.clone();
    let mut enc = r.device.create_command_encoder(&Default::default());
    r.encode_frame(&mut enc, &target, &baked, time, c, &events, demo);
    r.queue.submit([enc.finish()]);
    r.read_rgba(&target)
}

/// A frame partway into a schedule transition (FrameCapture.Transition): the look being left and
/// how far (0 to 1) the switch to the current one has gone.
pub struct Transition {
    pub from: WallpaperConfig,
    pub progress: f64,
    pub style: TransitionStyle,
}

/// Parses `SCENE:PROGRESS[:STYLE]` (as the Mac's `--transition-from`): the look being left is the
/// current settings switched to SCENE, as picking it in the gallery would.
fn transition_from(spec: &str, c: &WallpaperConfig) -> Result<Transition, String> {
    let usage = "--transition-from expects <scene>:<progress>[:<style>]";
    let parts: Vec<&str> = spec.split(':').collect();
    if parts.len() < 2 {
        return Err(usage.into());
    }
    let kind = SceneKind::from_raw(parts[0]).ok_or(usage)?;
    let progress: f64 = parts[1].parse().map_err(|_| usage)?;
    let style = match parts.get(2) {
        Some(s) => TransitionStyle::from_raw(s).ok_or(usage)?,
        None => TransitionStyle::Dissolve,
    };
    let mut from = c.clone();
    from.set_scene(kind);
    Ok(Transition { from, progress, style })
}

/// `render_cells` partway through a transition: both looks with their own bakes, mixed with seed
/// 1 as the Mac's snapshots do.
#[allow(clippy::too_many_arguments)]
pub fn render_transition_cells(r: &Renderer, c: &WallpaperConfig, w: u32, h: u32, time: f64, events_enabled: bool,
                               demo: &HashMap<u64, f64>, t: &Transition) -> Vec<u8> {
    let baked = r.bake(w, h, c, None);
    let from_baked = r.bake(w, h, &t.from, None);
    let target = r.make_target(w, h, wgpu::TextureUsages::COPY_SRC);
    let a = r.make_target(w, h, wgpu::TextureUsages::empty());
    let b = r.make_target(w, h, wgpu::TextureUsages::empty());
    let mut events = EventSchedule::new(1);
    events.enabled = events_enabled;
    events.demo = demo.clone();
    let mut enc = r.device.create_command_encoder(&Default::default());
    r.encode_frame(&mut enc, &a, &from_baked, time, &t.from, &events, demo);
    r.encode_frame(&mut enc, &b, &baked, time, c, &events, demo);
    r.encode_transition(&mut enc, &target, &a, &b, t.progress, 1.0, t.style, &t.from, c);
    r.queue.submit([enc.finish()]);
    r.read_rgba(&target)
}

/// A frame upscaled with nearest-neighbor like the live wallpaper, anchored at the top left and
/// cropped to `size`.
#[allow(clippy::too_many_arguments)]
pub fn snapshot(r: &Renderer, c: &WallpaperConfig, size: (u32, u32), time: f64, events: bool, demo: &HashMap<u64, f64>,
                transition: Option<&Transition>) -> Vec<u8> {
    let px = c.pixel_size.max(1) as u32;
    let (w, h) = (size.0.div_ceil(px), size.1.div_ceil(px));
    let cells = match transition {
        Some(t) => render_transition_cells(r, c, w, h, time, events, demo, t),
        None => render_cells(r, c, w, h, time, events, demo),
    };
    let mut out = vec![0u8; (size.0 * size.1 * 4) as usize];
    for y in 0..size.1 {
        for x in 0..size.0 {
            let s = (((y / px) * w + x / px) * 4) as usize;
            let d = ((y * size.0 + x) * 4) as usize;
            out[d..d + 4].copy_from_slice(&cells[s..s + 4]);
        }
    }
    out
}

pub fn write_png(path: &str, w: u32, h: u32, rgba: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| format!("could not write {path}: {e}"))?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(rgba).map_err(|e| e.to_string())?;
    Ok(())
}

/// Wall time per frame with the GPU drained after each one, so it bounds the GPU time from
/// above (the budget is about 2 ms per frame).
fn benchmark(r: &Renderer, c: &WallpaperConfig, size: (u32, u32), frames: u32) -> Result<(), String> {
    let px = c.pixel_size.max(1) as u32;
    let (w, h) = (size.0.div_ceil(px), size.1.div_ceil(px));
    let t0 = Instant::now();
    let baked = r.bake(w, h, c, None);
    r.device.poll(wgpu::Maintain::Wait);
    let bake_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let target = r.make_target(w, h, wgpu::TextureUsages::empty());
    let events = EventSchedule::new(1);
    let demo = HashMap::new();
    // GPU time from timestamps written before and after each frame's passes, where supported
    let gpu = r.device.features().contains(wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS);
    let queries = gpu.then(|| r.device.create_query_set(&wgpu::QuerySetDescriptor { label: None, ty: wgpu::QueryType::Timestamp, count: 2 }));
    let resolve = r.device.create_buffer(&wgpu::BufferDescriptor {
        label: None, size: 16, usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC, mapped_at_creation: false,
    });
    let readback = r.device.create_buffer(&wgpu::BufferDescriptor {
        label: None, size: 16, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false,
    });
    let period = r.queue.get_timestamp_period() as f64;
    let mut wall = Vec::new();
    let mut gpu_ms = Vec::new();
    for i in 0..frames + 10 {
        let t = Instant::now();
        let mut enc = r.device.create_command_encoder(&Default::default());
        if let Some(q) = &queries {
            enc.write_timestamp(q, 0);
        }
        r.encode_frame(&mut enc, &target, &baked, 300.0 + i as f64 / 24.0, c, &events, &demo);
        if let Some(q) = &queries {
            enc.write_timestamp(q, 1);
            enc.resolve_query_set(q, 0..2, &resolve, 0);
            enc.copy_buffer_to_buffer(&resolve, 0, &readback, 0, 16);
        }
        r.queue.submit([enc.finish()]);
        r.device.poll(wgpu::Maintain::Wait);
        if queries.is_some() {
            let slice = readback.slice(..);
            slice.map_async(wgpu::MapMode::Read, |_| {});
            r.device.poll(wgpu::Maintain::Wait);
            let ts: [u64; 2] = bytemuck::pod_read_unaligned(&slice.get_mapped_range()[..16]);
            readback.unmap();
            if i >= 10 {
                gpu_ms.push(ts[1].wrapping_sub(ts[0]) as f64 * period / 1e6);
            }
        }
        if i >= 10 {
            wall.push(t.elapsed().as_secs_f64() * 1000.0);
        }
    }
    let stats = |v: &mut Vec<f64>| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        (v[v.len() / 2], v[v.len() * 95 / 100])
    };
    println!("{} at {}x{} ({}x{} shaded) on {}", c.scene.title(), size.0, size.1, w, h, r.adapter_info.name);
    println!("  bake {bake_ms:.1} ms");
    if !gpu_ms.is_empty() {
        let (m, p) = stats(&mut gpu_ms);
        println!("  GPU per frame: median {m:.2} ms, p95 {p:.2} ms");
    }
    let (m, p) = stats(&mut wall);
    println!("  wall clock per frame (GPU drained each time): median {m:.2} ms, p95 {p:.2} ms");
    Ok(())
}
