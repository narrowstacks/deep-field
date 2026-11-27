//! The lock screen still (App/LockScreenStill.swift), opt-in through `lock_screen_still`. The
//! Mac keeps a still as each screen's desktop picture, which its lock screen shows. Windows has a
//! lock screen picture of its own, so the still goes there instead, through WinRT's `LockScreen`
//! (one picture for every display, rendered at the primary display's size).
//!
//! Before replacing the picture it keeps a copy of the one it replaces, and puts that back when
//! the setting is turned off. The still is re-rendered, a few seconds after the look of the scene
//! changes; a picture the user has since chosen in Windows' settings is left alone until they
//! press Set Now. Quitting leaves the still in place, which is the point.
//!
//! The wallpaper does the work, since it has the renderer and runs all the time. The Customize
//! window shows its status from `lock-screen.json` and asks for Set Now with a request file.

use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::config::{DitherPattern, SceneKind, WallpaperConfig, DEFAULT_TILT};
use crate::renderer::Renderer;

/// Smooth stills are shaded at up to about this many pixels (larger screens render at half or a
/// third of their resolution and are scaled up smoothly), which keeps the one-off bake under
/// roughly 0.5 GB for the black hole.
const MAX_SHADED_PIXELS: f64 = 6_000_000.0;

const LEFT_ALONE: &str = "Not updated: you chose another lock screen picture. Use Set Now to replace it.";

pub fn folder() -> PathBuf {
    crate::config_store::dir().join("Lock Screen")
}

pub fn state_path() -> PathBuf {
    crate::config_store::dir().join("lock-screen.json")
}

/// Written by the Customize window's Set Now; the wallpaper picks it up within a second.
pub fn request_path() -> PathBuf {
    crate::config_store::dir().join("lock-screen-request")
}

/// What the wallpaper remembers between runs, and what it tells the Customize window.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LockState {
    /// a copy of the picture the still replaced, to put back
    pub original: Option<PathBuf>,
    /// A hash of the lock screen picture as Windows kept it after we set ours. Windows stores its
    /// own copy, so comparing the picture is the way to tell whether the user changed it since.
    pub ours: Option<u64>,
    /// the still the lock screen shows
    pub current: Option<PathBuf>,
    /// what was last done, or what went wrong
    pub status: String,
    /// a render is in flight
    pub busy: bool,
}

impl LockState {
    pub fn load() -> LockState {
        std::fs::read_to_string(state_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    fn save(&self) {
        let _ = std::fs::create_dir_all(crate::config_store::dir());
        let Ok(text) = serde_json::to_string_pretty(self) else { return };
        let p = state_path();
        let tmp = p.with_extension("json.tmp");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
}

/// Dithered (default): exactly the wallpaper's pixel size, color levels and dither pattern.
/// Smooth: no coarse pixels and 256 levels (the fine Bayer dither then only breaks up banding).
pub fn still_config(c: &WallpaperConfig) -> WallpaperConfig {
    let mut c = c.clone();
    if c.lock_screen_smooth {
        c.pixel_size = 1;
        c.levels = 256;
        c.dither = DitherPattern::Bayer8;
    }
    c
}

/// What the still depends on: the config minus settings that don't change it (frame rate, other
/// scenes' tilts; in smooth mode also the pixel look, which `still_config` overrides).
pub fn look(c: &WallpaperConfig) -> WallpaperConfig {
    let mut c = still_config(c);
    c.fps = 24;
    c.lock_screen_still = false;
    c.scene_tilt.clear();
    c.shared_tilt = DEFAULT_TILT;
    c.normalize_tilts();
    c
}

/// A moment where each scene looks like itself (events are off anyway).
pub fn representative_time(c: &WallpaperConfig) -> f64 {
    match c.scene {
        SceneKind::BlackHole => 444.0,
        // the stream wrapping round the hole
        SceneKind::TidalDisruption => 0.55 * c.tde_cycle_minutes * 60.0,
        // whole turns: beams on the diagonals
        SceneKind::Pulsar => 20.0 * c.pulsar_period,
        // both stars clear of each other
        SceneKind::Binary => 0.72 * c.star_orbit_minutes * 60.0,
        SceneKind::Trinary => 0.33 * c.star_orbit_minutes * 60.0,
        // star close-up: between eruptions
        _ => 130.0,
    }
}

/// Shaded cells blown up to the screen: with crisp edges like the live wallpaper (dithered), or
/// bilinearly (a smooth still shaded below native resolution).
pub fn upscale(cells: &[u8], w: u32, h: u32, tw: u32, th: u32, nearest: bool) -> Vec<u8> {
    let mut out = vec![0u8; (tw * th * 4) as usize];
    let at = |x: u32, y: u32, k: usize| cells[((y.min(h - 1) * w + x.min(w - 1)) * 4) as usize + k] as f32;
    for y in 0..th {
        for x in 0..tw {
            let d = ((y * tw + x) * 4) as usize;
            if nearest {
                let (sx, sy) = ((x as u64 * w as u64 / tw as u64) as u32, (y as u64 * h as u64 / th as u64) as u32);
                let s = ((sy * w + sx) * 4) as usize;
                out[d..d + 4].copy_from_slice(&cells[s..s + 4]);
            } else {
                // pixel centers line up, as a smooth scaler samples
                let fx = ((x as f32 + 0.5) * w as f32 / tw as f32 - 0.5).max(0.0);
                let fy = ((y as f32 + 0.5) * h as f32 / th as f32 - 0.5).max(0.0);
                let (x0, y0) = (fx as u32, fy as u32);
                let (tx, ty) = (fx - x0 as f32, fy - y0 as f32);
                for k in 0..3 {
                    let top = at(x0, y0, k) * (1.0 - tx) + at(x0 + 1, y0, k) * tx;
                    let bottom = at(x0, y0 + 1, k) * (1.0 - tx) + at(x0 + 1, y0 + 1, k) * tx;
                    out[d + k] = (top * (1.0 - ty) + bottom * ty).round() as u8;
                }
                out[d + 3] = 255;
            }
        }
    }
    out
}

/// FNV-1a, enough to tell one picture from another.
fn hash(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, &b| (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3))
}

// MARK: WinRT

mod winrt {
    use windows::core::HSTRING;
    use windows::Storage::StorageFile;
    use windows::Storage::Streams::DataReader;
    use windows::System::UserProfile::LockScreen;
    use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

    /// WinRT on this thread, which the blocking calls below need.
    pub fn init() {
        unsafe {
            let _ = RoInitialize(RO_INIT_MULTITHREADED);
        }
    }

    /// The lock screen picture's bytes as Windows keeps them.
    pub fn current_image() -> Result<Vec<u8>, String> {
        let read = || -> windows::core::Result<Vec<u8>> {
            let stream = LockScreen::GetImageStream()?;
            let size = stream.Size()? as u32;
            let reader = DataReader::CreateDataReader(&stream.GetInputStreamAt(0)?)?;
            reader.LoadAsync(size)?.get()?;
            let mut buf = vec![0u8; size as usize];
            reader.ReadBytes(&mut buf)?;
            Ok(buf)
        };
        read().map_err(|e| e.message().to_string())
    }

    pub fn set_image(path: &std::path::Path) -> Result<(), String> {
        let set = || -> windows::core::Result<()> {
            let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path.as_os_str()))?.get()?;
            LockScreen::SetImageFileAsync(&file)?.get()
        };
        set().map_err(|e| e.message().to_string())
    }
}

/// The original picture's file extension, from its first bytes.
fn image_extension(bytes: &[u8]) -> &'static str {
    match bytes {
        [0x89, b'P', b'N', b'G', ..] => "png",
        [b'B', b'M', ..] => "bmp",
        _ => "jpg",
    }
}

// MARK: the wallpaper's side

/// The worker's jobs, done in order. It alone writes lock-screen.json, so a still set just
/// before the setting is turned off is on record for the restore that follows it.
enum Job {
    /// a still is being rendered, for the Customize window's status
    Busy,
    /// a rendered still to save and set, and whether to replace a picture the user chose
    Set { rgba: Vec<u8>, width: u32, height: u32, force: bool },
    Restore,
}

pub struct LockScreenStill {
    was_enabled: bool,
    last_look: WallpaperConfig,
    due: Option<(Instant, bool)>,
    jobs: Sender<Job>,
}

impl LockScreenStill {
    pub fn start(c: &WallpaperConfig) -> LockScreenStill {
        let (jobs, job_rx) = mpsc::channel::<Job>();
        // the WinRT calls block, and a still's PNG takes a moment to write
        std::thread::Builder::new()
            .name("lock screen".into())
            .spawn(move || worker(job_rx))
            .expect("lock screen thread");
        let mut s = LockScreenStill { was_enabled: c.lock_screen_still, last_look: look(c), due: None, jobs };
        // catch up with changes made while the wallpaper wasn't running (a new build, a new look)
        if s.was_enabled {
            s.due = Some((Instant::now() + Duration::from_secs(2), false));
        } else {
            s.restore();
        }
        s
    }

    /// Called whenever the config may have changed.
    pub fn config_changed(&mut self, c: &WallpaperConfig) {
        if c.lock_screen_still != self.was_enabled {
            self.was_enabled = c.lock_screen_still;
            self.last_look = look(c);
            if self.was_enabled {
                self.due = Some((Instant::now(), true));
            } else {
                self.restore();
            }
            return;
        }
        let l = look(c);
        if self.was_enabled && l != self.last_look {
            self.last_look = l;
            self.due = Some((Instant::now() + Duration::from_secs(3), false));
        }
    }

    fn restore(&mut self) {
        self.due = None;
        let _ = self.jobs.send(Job::Restore);
    }

    /// Each second: Set Now from the Customize window, a render that has come due, and finished
    /// work. `screen` is the primary display's size in pixels.
    pub fn tick(&mut self, r: &Renderer, c: &WallpaperConfig, screen: (u32, u32)) {
        if std::fs::remove_file(request_path()).is_ok() && c.lock_screen_still {
            self.due = Some((Instant::now(), true));
        }
        let Some((when, force)) = self.due else { return };
        if Instant::now() < when || !c.lock_screen_still {
            return;
        }
        self.due = None;
        let _ = self.jobs.send(Job::Busy);
        let (tw, th) = (screen.0.max(1), screen.1.max(1));
        let rgba = render_still(r, c, (tw, th));
        let _ = self.jobs.send(Job::Set { rgba, width: tw, height: th, force });
    }
}

/// The still for a screen of size pixels, as RGBA rows (also --snapshot --lock-screen).
pub fn render_still(r: &Renderer, c: &WallpaperConfig, size: (u32, u32)) -> Vec<u8> {
    let cfg = still_config(c);
    let (tw, th) = size;
    // dithered: shade one pixel per wallpaper cell and blow it up with crisp edges, like the
    // live wallpaper; smooth: shade at (up to) native resolution
    let factor = if cfg.lock_screen_smooth {
        ((tw as f64 * th as f64 / MAX_SHADED_PIXELS).sqrt().ceil() as u32).max(1)
    } else {
        cfg.pixel_size.max(1) as u32
    };
    let (w, h) = (tw.div_ceil(factor), th.div_ceil(factor));
    let cells = crate::capture::render_cells(r, &cfg, w, h, representative_time(&cfg), false, &Default::default());
    upscale(&cells, w, h, tw, th, !cfg.lock_screen_smooth)
}

fn worker(jobs: Receiver<Job>) {
    winrt::init();
    for job in jobs {
        let state = match job {
            Job::Busy => {
                let mut s = LockState::load();
                s.busy = true;
                s.status.clear();
                s
            }
            Job::Set { rgba, width, height, force } => set_still(&rgba, width, height, force),
            Job::Restore => {
                let s = restore_original();
                if s == LockState::load() {
                    continue;
                }
                s
            }
        };
        state.save();
    }
}

/// Saves the still and sets it, first keeping a copy of the picture it replaces.
fn set_still(rgba: &[u8], width: u32, height: u32, force: bool) -> LockState {
    let mut state = LockState::load();
    state.busy = false;
    let shown = match winrt::current_image() {
        Ok(b) => b,
        Err(e) => {
            state.status = format!("Couldn't read the lock screen picture: {e}");
            return state;
        }
    };
    let ours = state.ours == Some(hash(&shown));
    if !ours {
        // the user picked another picture since we last set ours: leave it unless forced
        if state.original.is_some() && !force {
            state.status = LEFT_ALONE.into();
            return state;
        }
        let _ = std::fs::create_dir_all(folder());
        let copy = folder().join(format!("original.{}", image_extension(&shown)));
        if let Err(e) = std::fs::write(&copy, &shown) {
            state.status = format!("Couldn't keep a copy of your lock screen picture: {e}");
            return state;
        }
        state.original = Some(copy);
    }
    let _ = std::fs::create_dir_all(folder());
    let millis = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis());
    let path = folder().join(format!("still-{millis}.png"));
    if let Err(e) = crate::capture::write_png(&path.to_string_lossy(), width, height, rgba) {
        state.status = format!("Couldn't make the still: {e}");
        return state;
    }
    if let Err(e) = winrt::set_image(&path) {
        let _ = std::fs::remove_file(&path);
        state.status = format!("Couldn't set the lock screen picture: {e}");
        return state;
    }
    state.ours = winrt::current_image().ok().map(|b| hash(&b));
    state.current = Some(path);
    state.status = format!("Set at {}.", crate::schedule::local_time_string(crate::schedule::now()));
    clean_up(&state);
    state
}

/// Puts back the picture the still replaced, if the still is still showing. If the user has
/// since chosen another, there's nothing to put back.
fn restore_original() -> LockState {
    let mut state = LockState::load();
    state.busy = false;
    if state.original.is_none() && state.current.is_none() {
        return state;
    }
    let ours = winrt::current_image().ok().is_some_and(|b| Some(hash(&b)) == state.ours);
    state.status.clear();
    if ours {
        match &state.original {
            Some(original) if original.exists() => match winrt::set_image(original) {
                Ok(()) => state.status = "Restored your lock screen picture.".into(),
                Err(e) => {
                    state.status = format!("Couldn't restore your lock screen picture: {e}");
                    return state;
                }
            },
            _ => {
                state.status = "The original picture is gone; the still stays.".into();
                return state;
            }
        }
    }
    let original = state.original.take();
    state.ours = None;
    state.current = None;
    clean_up(&state);
    if let Some(o) = original {
        let _ = std::fs::remove_file(o);
    }
    state
}

/// Deletes stills the lock screen doesn't use any more (Windows keeps its own copy, but the
/// current one stays for reference).
fn clean_up(state: &LockState) {
    let Ok(files) = std::fs::read_dir(folder()) else { return };
    for f in files.flatten() {
        let p = f.path();
        let still = p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("still-") && n.ends_with(".png"));
        if still && state.current.as_ref() != Some(&p) {
            let _ = std::fs::remove_file(p);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn look_ignores_what_the_still_does_not_show() {
        let c = WallpaperConfig::default();
        let mut d = c.clone();
        d.fps = 60;
        d.lock_screen_still = true;
        assert!(look(&c) == look(&d), "the frame rate or the switch itself changed the look");
        d.saturation = 1.9;
        assert!(look(&c) != look(&d), "a color change didn't change the look");
        // smooth mode overrides the pixel look, so changing it there doesn't re-render
        let mut s = c.clone();
        s.lock_screen_smooth = true;
        let mut t = s.clone();
        t.pixel_size = 6;
        assert!(look(&s) == look(&t));
    }

    #[test]
    fn upscale_keeps_crisp_cells_and_smooth_gradients() {
        let cells = [0u8, 0, 0, 255, 200, 100, 50, 255];
        let crisp = upscale(&cells, 2, 1, 4, 1, true);
        assert_eq!(&crisp[0..4], &[0, 0, 0, 255]);
        assert_eq!(&crisp[4..8], &[0, 0, 0, 255]);
        assert_eq!(&crisp[8..12], &[200, 100, 50, 255]);
        let smooth = upscale(&cells, 2, 1, 4, 1, false);
        // the second pixel sits a quarter of the way from the first cell's center to the second's
        assert_eq!(smooth[4], 50);
        assert_eq!(smooth[16 - 4], 200);
    }
}

#[cfg(test)]
mod system_tests {
    /// Reads (never sets) this machine's lock screen picture through WinRT. Ignored by default
    /// since it depends on the machine: `cargo test --lib -- --ignored lock_screen`.
    #[test]
    #[ignore]
    fn reads_the_lock_screen_picture() {
        super::winrt::init();
        let bytes = super::winrt::current_image().expect("lock screen picture");
        assert!(bytes.len() > 1000, "only {} bytes", bytes.len());
        println!("{} bytes, .{}", bytes.len(), super::image_extension(&bytes));
    }
}
