//! Events started by hand ("Show Me", ConfigStore.demoEvents on the Mac). The Customize window
//! and the wallpaper are separate programs with their own clocks, so a start is written to
//! %APPDATA%\DeepField\demo.json as wall-clock time, and each turns it into its own elapsed time:
//! the event then plays in the preview and on every screen at once.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::SystemTime;

use crate::config_store::dir;
use crate::events::DemoMap;

/// Starts are forgotten after the longest event has long finished (the eclipse's eruption runs
/// about 13 minutes).
const KEEP_SECONDS: f64 = 3600.0;

fn unix_now() -> f64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn path() -> PathBuf {
    dir().join("demo.json")
}

/// Event kind id to the wall-clock second it was started.
fn read() -> HashMap<u64, f64> {
    let Ok(text) = std::fs::read_to_string(path()) else { return HashMap::new() };
    let map: HashMap<String, f64> = serde_json::from_str(&text).unwrap_or_default();
    map.into_iter().filter_map(|(k, v)| Some((k.parse().ok()?, v))).collect()
}

/// Starts event `kind` now, wherever Deep Field is drawing.
pub fn request(kind: u64) {
    let now = unix_now();
    let mut starts = read();
    starts.retain(|_, t| now - *t < KEEP_SECONDS);
    starts.insert(kind, now);
    let text: HashMap<String, f64> = starts.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
    let _ = std::fs::create_dir_all(dir());
    let tmp = path().with_extension("json.tmp");
    if std::fs::write(&tmp, serde_json::to_string(&text).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, path());
    }
}

/// Watches demo.json and gives the starts on this program's clock.
#[derive(Default)]
pub struct DemoWatcher {
    modified: Option<SystemTime>,
    starts: HashMap<u64, f64>,
}

impl DemoWatcher {
    /// True when the file changed since the last look.
    pub fn poll(&mut self) -> bool {
        let m = std::fs::metadata(path()).and_then(|m| m.modified()).ok();
        if m == self.modified {
            return false;
        }
        self.modified = m;
        self.starts = read();
        true
    }

    /// The starts as times on a clock that reads `elapsed` now.
    pub fn demo(&self, elapsed: f64) -> DemoMap {
        let now = unix_now();
        self.starts.iter().filter(|(_, t)| now - **t < KEEP_SECONDS).map(|(&k, &t)| (k, elapsed - (now - t))).collect()
    }
}

fn clock_path() -> PathBuf {
    dir().join("wallpaper-clock")
}

/// Called as the wallpaper starts: when its clock read 0, so the Customize window can tell what
/// moment the wallpaper is showing (for whether a Show Me event would be hidden).
pub fn record_wallpaper_clock(elapsed_now: f64) {
    let _ = std::fs::create_dir_all(dir());
    let _ = std::fs::write(clock_path(), format!("{}", unix_now() - elapsed_now));
}

/// The running wallpaper's clock now, if it has recorded one.
pub fn wallpaper_elapsed() -> Option<f64> {
    let start: f64 = std::fs::read_to_string(clock_path()).ok()?.trim().parse().ok()?;
    Some(unix_now() - start)
}
