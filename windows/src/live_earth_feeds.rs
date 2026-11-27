//! Live Earth's two live layers: the latest global cloud map and NOAA's aurora forecast (after
//! Rendering/LiveEarthFeeds.swift). Each is fetched while the scene is showing and its layer is
//! on, saved to %APPDATA%\DeepField\LiveEarth, and read back from there on later launches, so the
//! scene keeps its last clouds and aurora with no connection. Before the first fetch ever
//! succeeds, a copy bundled in Resources\Earth stands in.
//!
//! Sources (both free, no key):
//! - clouds: https://clouds.matteason.co.uk, a global infrared cloud composite from geostationary
//!   weather satellites, refreshed every 3 hours (centered on 0 degrees, like our maps)
//! - aurora: NOAA SWPC's OVATION model, the chance of aurora overhead on a 1 degree grid for the
//!   next half hour or so, refreshed every few minutes
//!
//! Downloads run on a background thread, and a finished one is uploaded on a later frame, so a
//! frame never waits for the network. Requests carry nothing about the user: a plain GET with a
//! generic User-Agent.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use crate::earth_maps::{self, Image};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Feed {
    Clouds = 0,
    Aurora = 1,
}

pub const FEEDS: [Feed; 2] = [Feed::Clouds, Feed::Aurora];

impl Feed {
    pub fn url(self) -> &'static str {
        match self {
            Feed::Clouds => "https://clouds.matteason.co.uk/images/2048x1024/clouds.jpg",
            Feed::Aurora => "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json",
        }
    }
    /// The image kept on disk (the aurora's JSON is turned into an image first).
    fn file_name(self) -> &'static str {
        if self == Feed::Clouds { "clouds.jpg" } else { "aurora.png" }
    }
    fn fallback_name(self) -> &'static str {
        if self == Feed::Clouds { "clouds-fallback.jpg" } else { "aurora-fallback.png" }
    }
    /// How often the source changes, so how often it's worth asking.
    fn refresh_interval(self) -> Duration {
        Duration::from_secs(if self == Feed::Clouds { 3 * 3600 } else { 20 * 60 })
    }
    fn name(self) -> &'static str {
        if self == Feed::Clouds { "clouds" } else { "aurora" }
    }
}

/// What the background downloads share with the render thread.
#[derive(Default)]
struct Shared {
    /// When the data on disk was fetched; None while showing the bundled copy.
    fetched: Option<SystemTime>,
    last_attempt: Option<Instant>,
    in_flight: bool,
    failed: bool,
    /// A freshly downloaded image, waiting to be uploaded by the render thread.
    ready: Option<Image>,
}

/// The cache folder, %APPDATA%\DeepField\LiveEarth.
pub fn directory() -> PathBuf {
    crate::config_store::dir().join("LiveEarth")
}

fn cache_path(feed: Feed) -> PathBuf {
    directory().join(feed.file_name())
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

/// The User-Agent every request sends: the app's name and nothing else.
pub const USER_AGENT: &str = "DeepField";

/// A GET with a timeout; the body when the server answers 2xx.
pub fn download(url: &str, timeout: Duration) -> Result<Vec<u8>, String> {
    let agent = ureq::AgentBuilder::new().timeout(timeout).user_agent(USER_AGENT).build();
    let resp = agent.get(url).call().map_err(|e| e.to_string())?;
    let mut body = Vec::new();
    std::io::Read::read_to_end(&mut resp.into_reader(), &mut body).map_err(|e| e.to_string())?;
    Ok(body)
}

pub struct LiveEarthFeeds {
    shared: [Arc<Mutex<Shared>>; 2],
    textures: RefCell<[Option<Rc<wgpu::Texture>>; 2]>,
    loaded: [Cell<bool>; 2],
    /// Off for command-line renders, so a snapshot never reaches the network.
    pub allow_network: Cell<bool>,
    /// Off for command-line renders too (unless `--live-earth-cache`), so they read the bundled
    /// maps and come out the same every time.
    pub use_cache: Cell<bool>,
}

impl Default for LiveEarthFeeds {
    fn default() -> Self {
        LiveEarthFeeds {
            shared: [Arc::default(), Arc::default()],
            textures: RefCell::new([None, None]),
            loaded: [Cell::new(false), Cell::new(false)],
            allow_network: Cell::new(true),
            use_cache: Cell::new(true),
        }
    }
}

impl LiveEarthFeeds {
    /// The feed's texture for this frame. Loads it from disk the first time and asks for a
    /// fresh copy in the background when it's out of date; the new one shows on a later frame.
    pub fn texture(&self, feed: Feed, device: &wgpu::Device, queue: &wgpu::Queue) -> Option<Rc<wgpu::Texture>> {
        let i = feed as usize;
        let shared = &self.shared[i];
        if !self.loaded[i].get() {
            self.loaded[i].set(true);
            let cached = cache_path(feed);
            let mut tex = None;
            if self.use_cache.get() {
                tex = earth_maps::load(device, queue, &cached, false);
                if tex.is_some() {
                    shared.lock().unwrap().fetched = mtime(&cached);
                }
            }
            if tex.is_none() {
                tex = earth_maps::bundled(feed.fallback_name()).and_then(|p| earth_maps::load(device, queue, &p, false));
            }
            self.textures.borrow_mut()[i] = tex.map(Rc::new);
        }
        let mut st = shared.lock().unwrap();
        if let Some(img) = st.ready.take() {
            self.textures.borrow_mut()[i] = Some(Rc::new(earth_maps::upload(device, queue, &img, true)));
        }
        let stale = st.fetched.and_then(|f| f.elapsed().ok()).map_or(true, |age| age > feed.refresh_interval());
        // after a failure, wait a while before trying again
        let wait = Duration::from_secs(if st.failed { 600 } else { 60 });
        let retry_ok = st.last_attempt.map_or(true, |t| t.elapsed() > wait);
        if self.allow_network.get() && stale && retry_ok && !st.in_flight {
            st.in_flight = true;
            st.last_attempt = Some(Instant::now());
            drop(st);
            let shared = shared.clone();
            std::thread::spawn(move || refresh(feed, &shared));
        }
        self.textures.borrow()[i].clone()
    }
}

/// Fetches a feed, stores it, and hands the decoded image to the render thread.
fn refresh(feed: Feed, shared: &Mutex<Shared>) -> bool {
    let result = download(feed.url(), Duration::from_secs(60)).and_then(|data| store(feed, &data).ok_or("bad data".into()));
    let image = result.as_ref().ok().and_then(|path| earth_maps::read(path, false));
    let mut st = shared.lock().unwrap();
    st.in_flight = false;
    st.failed = image.is_none();
    if let Some(img) = image {
        st.ready = Some(img);
        st.fetched = Some(SystemTime::now());
        true
    } else {
        let why = result.err().unwrap_or_else(|| "unreadable image".into());
        eprintln!("deepfield: couldn't update the Live Earth {} map: {why}", feed.name());
        false
    }
}

/// Writes the fetched data to the cache as an image, replacing the old one only when the new
/// one is good.
fn store(feed: Feed, data: &[u8]) -> Option<PathBuf> {
    std::fs::create_dir_all(directory()).ok()?;
    let path = cache_path(feed);
    match feed {
        Feed::Clouds => {
            let img = earth_maps::decode(data, false)?;
            if img.width < 512 {
                return None;
            }
            let tmp = path.with_extension("tmp");
            std::fs::write(&tmp, data).ok()?;
            std::fs::rename(&tmp, &path).ok()?;
        }
        Feed::Aurora => {
            let grid = aurora_grid(data)?;
            if !earth_maps::write_gray_png(&path, 360, 181, &grid) {
                return None;
            }
        }
    }
    Some(path)
}

/// NOAA's OVATION JSON as a 360x181 grid: column i is longitude i degrees east, row j latitude
/// 90 - j, value the percent chance of aurora overhead scaled to 0...255 (as in
/// make_earth_maps.py's aurora_fallback).
pub fn aurora_grid(data: &[u8]) -> Option<Vec<u8>> {
    let json: serde_json::Value = serde_json::from_slice(data).ok()?;
    let coords = json.get("coordinates")?.as_array()?;
    if coords.len() <= 1000 {
        return None;
    }
    let mut grid = vec![0u8; 360 * 181];
    for c in coords {
        let Some(c) = c.as_array() else { continue };
        if c.len() < 3 {
            continue;
        }
        let (Some(lon), Some(lat), Some(v)) = (c[0].as_f64(), c[1].as_f64(), c[2].as_f64()) else { continue };
        // Swift's rounded() rounds half away from zero, like Rust's round()
        let lon = ((lon.round() as i64) % 360 + 360) % 360;
        let lat = lat.round() as i64;
        if !(-90..=90).contains(&lat) {
            continue;
        }
        grid[((90 - lat) * 360 + lon) as usize] = (v * 2.55 + 0.5).max(0.0).min(255.0) as u8;
    }
    Some(grid)
}

/// `--fetch-live-earth`: fetch both feeds now and wait, so the cache is fresh.
pub fn fetch_now() -> bool {
    let mut ok = true;
    for feed in FEEDS {
        let shared = Mutex::new(Shared::default());
        let good = refresh(feed, &shared);
        if good {
            println!("{}: saved to {}", feed.name(), cache_path(feed).display());
        } else {
            println!("{}: failed", feed.name());
        }
        ok &= good;
    }
    ok
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ovation_json_to_grid() {
        let mut coords = Vec::new();
        for lon in 0..360 {
            for lat in -90..=90 {
                let v = if lon == 10 && lat == 65 { 50.0 } else { 0.0 };
                coords.push(serde_json::json!([lon, lat, v]));
            }
        }
        let json = serde_json::json!({ "coordinates": coords }).to_string();
        let g = aurora_grid(json.as_bytes()).unwrap();
        // 50 * 2.55 + 0.5 is a hair under 128 in floating point, and truncates (as in Swift)
        assert_eq!(g[(90 - 65) * 360 + 10], 127);
        assert_eq!(g.iter().filter(|&&v| v > 0).count(), 1);
    }
}
