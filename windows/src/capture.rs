//! Command-line rendering: snapshots and the benchmark (after Dev/Snapshot.swift,
//! Rendering/FrameCapture.swift and Dev/Benchmark.swift).

use std::collections::HashMap;
use std::time::Instant;

use crate::config::{SceneKind, WallpaperConfig};
use crate::events::EventSchedule;
use crate::renderer::Renderer;

struct Opts {
    snapshot: Option<String>,
    benchmark: bool,
    scene: Option<SceneKind>,
    size: (u32, u32),
    time: f64,
    config: Option<String>,
    events: bool,
    demo: HashMap<u64, f64>,
    frames: u32,
}

fn parse(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts {
        snapshot: None, benchmark: false, scene: None, size: (1720, 720), time: 300.0,
        config: None, events: true, demo: HashMap::new(), frames: 120,
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
            "--demo" => {
                let s = val("--demo")?;
                let (id, start) = s.split_once(':').ok_or("usage: --demo ID:START")?;
                o.demo.insert(id.parse().map_err(|_| "bad --demo id")?, start.parse().map_err(|_| "bad --demo start")?);
            }
            other => return Err(format!("usage: unknown option {other}")),
        }
    }
    Ok(o)
}

fn config(o: &Opts) -> Result<WallpaperConfig, String> {
    let mut c = match &o.config {
        Some(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
            serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?
        }
        None => WallpaperConfig::default(),
    };
    if let Some(s) = o.scene {
        c.scene = s;
    }
    if !c.scene.is_ported() {
        return Err(format!("the {} scene isn't ported to Windows yet", c.scene.raw()));
    }
    Ok(c)
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
    let o = parse(args)?;
    let c = config(&o)?;
    let r = Renderer::new()?;
    if let Some(path) = &o.snapshot {
        let img = snapshot(&r, &c, o.size, o.time, o.events, &o.demo);
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

/// A frame upscaled with nearest-neighbor like the live wallpaper, anchored at the top left and
/// cropped to `size`.
pub fn snapshot(r: &Renderer, c: &WallpaperConfig, size: (u32, u32), time: f64, events: bool, demo: &HashMap<u64, f64>) -> Vec<u8> {
    let px = c.pixel_size.max(1) as u32;
    let (w, h) = (size.0.div_ceil(px), size.1.div_ceil(px));
    let cells = render_cells(r, c, w, h, time, events, demo);
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
