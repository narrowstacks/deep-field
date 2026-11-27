//! The saved settings: %APPDATA%\DeepField\config.json, the same JSON keys as the macOS app's
//! WallpaperConfig, so a config exported from a Mac reads here (unknown keys are ignored).

use std::path::PathBuf;
use std::time::SystemTime;

use crate::config::WallpaperConfig;

pub struct ConfigStore {
    pub config: WallpaperConfig,
    path: PathBuf,
    modified: Option<SystemTime>,
}

pub fn dir() -> PathBuf {
    let base = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    base.join("DeepField")
}

fn mtime(p: &PathBuf) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

impl ConfigStore {
    pub fn load() -> ConfigStore {
        let path = dir().join("config.json");
        let config = Self::read(&path).unwrap_or_default();
        let mut store = ConfigStore { config, path, modified: None };
        if !store.path.exists() {
            store.save();
        }
        store.modified = mtime(&store.path);
        store
    }

    pub fn path(&self) -> &PathBuf {
        &self.path
    }

    /// Leniently, as `WallpaperConfig.decode` loads the Mac's: keys missing from older saves take
    /// their defaults, and one bad value falls back alone instead of resetting everything.
    fn read(path: &PathBuf) -> Option<WallpaperConfig> {
        let text = std::fs::read_to_string(path).ok()?;
        let c = WallpaperConfig::decode(&text);
        if c.is_none() {
            eprintln!("deepfield: {} is not valid; using the defaults", path.display());
        }
        c
    }

    pub fn save(&mut self) {
        let _ = std::fs::create_dir_all(dir());
        if let Ok(text) = serde_json::to_string_pretty(&self.config) {
            let _ = std::fs::write(&self.path, text);
        }
        self.modified = mtime(&self.path);
    }

    /// Picks up edits made to the file by hand; true when the config changed.
    pub fn reload_if_changed(&mut self) -> bool {
        let m = mtime(&self.path);
        if m == self.modified {
            return false;
        }
        self.modified = m;
        match Self::read(&self.path) {
            Some(c) => {
                self.config = c;
                true
            }
            None => false,
        }
    }
}
