//! What the Mac keeps in UserDefaults beside the config: whether the scene is on the desktop
//! (`wallpaperEnabled`, the menu's Show on Desktop) and whether the welcome guide has been seen.
//! Kept in %APPDATA%\DeepField\app-state.json, which the wallpaper and the Customize window both
//! read: the guide's Set as Wallpaper turns the desktop on from the other process.

use std::path::PathBuf;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppState {
    /// Off until the first launch's guide finishes with Set as Wallpaper, so nothing changes under
    /// someone who only opened the app to look.
    pub wallpaper_enabled: bool,
    pub welcome_shown: bool,
}

impl Default for AppState {
    fn default() -> AppState {
        AppState { wallpaper_enabled: true, welcome_shown: false }
    }
}

pub fn path() -> PathBuf {
    crate::config_store::dir().join("app-state.json")
}

fn mtime() -> Option<SystemTime> {
    std::fs::metadata(path()).and_then(|m| m.modified()).ok()
}

impl AppState {
    pub fn load() -> AppState {
        std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    /// Written beside the real file and renamed into place, so the other process never reads
    /// half of it.
    pub fn save(&self) {
        let p = path();
        let _ = std::fs::create_dir_all(crate::config_store::dir());
        let Ok(text) = serde_json::to_string_pretty(self) else { return };
        let tmp = p.with_extension("json.tmp");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }

    /// Changes one field and saves, reading the file first so the other process's change to the
    /// other field isn't written over.
    pub fn update(f: impl FnOnce(&mut AppState)) -> AppState {
        let mut s = AppState::load();
        f(&mut s);
        s.save();
        s
    }
}

/// True on a first launch: no saved settings, presets or schedule, and the guide not yet seen.
/// Worked out once at startup, before anything saves (the config store writes its defaults).
pub fn is_first_launch() -> bool {
    let dir = crate::config_store::dir();
    !["app-state.json", "config.json", "presets.json", "schedule.json"].iter().any(|f| dir.join(f).exists())
}

/// Notices the file changing underneath, by its time.
#[derive(Default)]
pub struct Watcher {
    modified: Option<SystemTime>,
}

impl Watcher {
    pub fn new() -> Watcher {
        Watcher { modified: mtime() }
    }

    /// The state, when the file changed since the last look.
    pub fn poll(&mut self) -> Option<AppState> {
        let m = mtime();
        if m == self.modified {
            return None;
        }
        self.modified = m;
        Some(AppState::load())
    }
}

const WALLPAPER_MUTEX: &str = r"Local\DeepFieldWallpaper";

/// Holds a named mutex for the life of the wallpaper process, false when another copy has it:
/// two copies would draw over each other behind the icons.
pub fn claim_wallpaper() -> bool {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows::Win32::System::Threading::CreateMutexW;
    unsafe {
        let handle = CreateMutexW(None, true, &HSTRING::from(WALLPAPER_MUTEX));
        if handle.is_ok() && GetLastError() != ERROR_ALREADY_EXISTS {
            // leaked on purpose: the mutex lives until the process exits
            std::mem::forget(handle);
            return true;
        }
        false
    }
}

/// Whether the wallpaper process is running, even with nothing on the desktop.
pub fn wallpaper_running() -> bool {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{OpenMutexW, SYNCHRONIZATION_SYNCHRONIZE};
    unsafe {
        match OpenMutexW(SYNCHRONIZATION_SYNCHRONIZE, false, &HSTRING::from(WALLPAPER_MUTEX)) {
            Ok(h) => {
                let _ = CloseHandle(h);
                true
            }
            Err(_) => false,
        }
    }
}
