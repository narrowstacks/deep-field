//! Preview and thumbnail rendering on a background thread, with one deepfield Renderer made once
//! and kept. The stage preview animates at a few frames a second with time advancing, reusing
//! its bake until a setting that changes the bake does; thumbnails are stills rendered on demand.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use deepfield::config::{SceneKind, WallpaperConfig};
use deepfield::events::EventSchedule;
use deepfield::renderer::{Baked, Renderer};

/// An RGBA8 frame.
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

pub enum Job {
    /// The stage preview: the config, the screen it stands for (pixels), the box it's shown in
    /// (device pixels) and whether it shows the middle of the screen at true pixel size.
    Preview { config: WallpaperConfig, screen: (u32, u32), shown: (u32, u32), actual: bool },
    /// Stop animating the preview (the window is minimized).
    Pause(bool),
    Thumbnail { kind: SceneKind, config: WallpaperConfig, cells: (u32, u32), shown: (u32, u32), generation: u64 },
}

pub enum Output {
    Preview(Frame),
    Thumbnail { kind: SceneKind, frame: Frame, generation: u64 },
    Failed(String),
}

/// The fastest the preview animates: the wallpaper's own frame rate up to this. A frame costs
/// about a millisecond on the GPU plus a few to read it back and hand it to the window.
const PREVIEW_MAX_FPS: f64 = 30.0;

pub fn spawn(out: Sender<Output>) -> Sender<Job> {
    let (tx, rx) = mpsc::channel::<Job>();
    // shader translation recurses deeply on big shaders, past a default thread stack
    std::thread::Builder::new()
        .name("preview".into())
        .stack_size(64 << 20)
        .spawn(move || worker(rx, out))
        .expect("preview thread");
    tx
}

struct PreviewState {
    config: WallpaperConfig,
    screen: (u32, u32),
    shown: (u32, u32),
    actual: bool,
}

fn worker(rx: Receiver<Job>, out: Sender<Output>) {
    let r = match Renderer::new() {
        Ok(r) => r,
        Err(e) => {
            let _ = out.send(Output::Failed(e));
            return;
        }
    };
    // The wallpaper keeps Live Earth's clouds and aurora fresh; the preview reads its cache
    // instead of downloading the same maps a second time.
    r.earth.feeds.allow_network.set(false);
    r.earth.feeds.use_cache.set(true);
    let start = Instant::now();
    let mut preview: Option<PreviewState> = None;
    let mut paused = false;
    let mut baked: Option<Baked> = None;
    let mut target: Option<wgpu::Texture> = None;
    let events = EventSchedule::new(1);
    let demo = HashMap::new();
    let mut thumbs: Vec<Job> = Vec::new();
    let mut next_frame = Instant::now();
    let mut warmed = false;

    loop {
        // wait for work, or for the next preview frame
        let timeout = if !thumbs.is_empty() {
            Duration::ZERO
        } else if preview.is_some() && !paused {
            next_frame.saturating_duration_since(Instant::now())
        } else {
            Duration::from_secs(3600)
        };
        let first = match rx.recv_timeout(timeout) {
            Ok(j) => Some(j),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => return,
        };
        // take everything queued, keeping only the newest preview request
        for job in first.into_iter().chain(rx.try_iter()) {
            match job {
                Job::Preview { config, screen, shown, actual } => {
                    if !warmed {
                        // every scene's shader at once, so the gallery fills in about two
                        // seconds and picking a scene doesn't wait for a compile
                        warmed = true;
                        r.warm(config.scene, &[Renderer::scene_format(&config)], 8);
                    }
                    preview = Some(PreviewState { config, screen, shown, actual });
                    next_frame = Instant::now();
                }
                Job::Pause(p) => paused = p,
                t @ Job::Thumbnail { .. } => thumbs.push(t),
            }
        }

        if let (Some(p), false) = (&preview, paused) {
            if Instant::now() >= next_frame {
                let px = p.config.pixel_size.max(1) as u32;
                let (w, h) = (p.screen.0.div_ceil(px).max(1), p.screen.1.div_ceil(px).max(1));
                let rebake = match &baked {
                    Some(b) => !b.matches(&p.config) || b.width != w || b.height != h,
                    None => true,
                };
                if rebake {
                    baked = Some(r.bake(w, h, &p.config, baked.take()));
                }
                if target.as_ref().map(|t| (t.width(), t.height())) != Some((w, h)) {
                    target = Some(r.make_target(w, h, wgpu::TextureUsages::COPY_SRC));
                }
                let t = target.as_ref().unwrap();
                let mut enc = r.device.create_command_encoder(&Default::default());
                // the same moment the wallpaper's own clock would be near, kept moving
                let time = 300.0 + start.elapsed().as_secs_f64();
                r.encode_frame(&mut enc, t, baked.as_ref().unwrap(), time, &p.config, &events, &demo);
                r.queue.submit([enc.finish()]);
                let cells = r.read_rgba(t);
                let frame = if p.actual {
                    actual_pixels(&cells, w, h, px, p.shown)
                } else {
                    fit(&cells, w, h, p.shown)
                };
                if out.send(Output::Preview(frame)).is_err() {
                    return;
                }
                let fps = (p.config.fps.max(1) as f64).min(PREVIEW_MAX_FPS);
                next_frame += Duration::from_secs_f64(1.0 / fps);
                // after a stall (a long thumbnail, a rebake) pick up from now rather than racing
                if next_frame < Instant::now() {
                    next_frame = Instant::now();
                }
            }
        }

        // one thumbnail per pass, so the preview keeps its pace while the gallery fills in
        if !thumbs.is_empty() {
            let Job::Thumbnail { kind, config, cells, shown, generation } = thumbs.remove(0) else { continue };
            // a newer request for the same scene replaces this one
            if thumbs.iter().any(|j| matches!(j, Job::Thumbnail { kind: k, .. } if *k == kind)) {
                continue;
            }
            let rgba = deepfield::capture::render_cells(&r, &config, cells.0, cells.1, 300.0, false, &demo);
            let frame = nearest(&rgba, cells.0, cells.1, shown);
            if out.send(Output::Thumbnail { kind, frame, generation }).is_err() {
                return;
            }
        }
    }
}

/// Upscales with nearest-neighbor, keeping the wallpaper's square pixels.
fn nearest(src: &[u8], w: u32, h: u32, shown: (u32, u32)) -> Frame {
    let (dw, dh) = (shown.0.max(1), shown.1.max(1));
    let mut rgba = vec![0u8; (dw * dh * 4) as usize];
    for y in 0..dh {
        let sy = ((y as u64 * h as u64) / dh as u64) as u32;
        for x in 0..dw {
            let sx = ((x as u64 * w as u64) / dw as u64) as u32;
            let s = ((sy * w + sx) * 4) as usize;
            let d = ((y * dw + x) * 4) as usize;
            rgba[d..d + 4].copy_from_slice(&src[s..s + 4]);
        }
    }
    Frame { width: dw, height: dh, rgba }
}

/// The whole screen fitted into the preview box. Where the screen's pixels are larger than the
/// box's they're drawn nearest-neighbor; where smaller, each box pixel averages the cells it
/// covers, as a scaled-down screen would look, rather than picking every other dither dot.
fn fit(cells: &[u8], w: u32, h: u32, shown: (u32, u32)) -> Frame {
    let (dw, dh) = (shown.0.max(1), shown.1.max(1));
    if dw >= w {
        return nearest(cells, w, h, shown);
    }
    let mut rgba = vec![0u8; (dw * dh * 4) as usize];
    for y in 0..dh {
        let y0 = (y as u64 * h as u64 / dh as u64) as u32;
        let y1 = (((y + 1) as u64 * h as u64 / dh as u64) as u32).max(y0 + 1).min(h);
        for x in 0..dw {
            let x0 = (x as u64 * w as u64 / dw as u64) as u32;
            let x1 = (((x + 1) as u64 * w as u64 / dw as u64) as u32).max(x0 + 1).min(w);
            let mut sum = [0u32; 3];
            let mut n = 0u32;
            for sy in y0..y1 {
                for sx in x0..x1 {
                    let s = ((sy * w + sx) * 4) as usize;
                    sum[0] += cells[s] as u32;
                    sum[1] += cells[s + 1] as u32;
                    sum[2] += cells[s + 2] as u32;
                    n += 1;
                }
            }
            let d = ((y * dw + x) * 4) as usize;
            rgba[d] = (sum[0] / n) as u8;
            rgba[d + 1] = (sum[1] / n) as u8;
            rgba[d + 2] = (sum[2] / n) as u8;
            rgba[d + 3] = 255;
        }
    }
    Frame { width: dw, height: dh, rgba }
}

/// The middle of the screen at its true size: each cell `px` box pixels wide.
fn actual_pixels(cells: &[u8], w: u32, h: u32, px: u32, shown: (u32, u32)) -> Frame {
    let (dw, dh) = (shown.0.max(1), shown.1.max(1));
    let mut rgba = vec![0u8; (dw * dh * 4) as usize];
    let ox = (w * px).saturating_sub(dw) / 2;
    let oy = (h * px).saturating_sub(dh) / 2;
    for y in 0..dh {
        let sy = ((oy + y) / px).min(h - 1);
        for x in 0..dw {
            let sx = ((ox + x) / px).min(w - 1);
            let s = ((sy * w + sx) * 4) as usize;
            let d = ((y * dw + x) * 4) as usize;
            rgba[d..d + 4].copy_from_slice(&cells[s..s + 4]);
        }
    }
    Frame { width: dw, height: dh, rgba }
}
