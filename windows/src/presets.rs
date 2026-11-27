//! Saved customizations (Config/UserPresets.swift): everything about the look, but not the
//! machine's own settings. Kept in %APPDATA%\DeepField\presets.json, a list in the Mac's own
//! format (`{"id", "name", "config", "includesPlace"}`), with import and export as `.deepfield`
//! files (`{"format": "deep-field-preset", "version": 1, "name", "config", "includesPlace"}`).

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::Serialize;
use serde_json::{Map, Value};

use crate::config::WallpaperConfig;
use crate::config_store::dir;

pub const FILE_EXTENSION: &str = "deepfield";

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserPreset {
    /// A UUID string, as Swift's `UUID` encodes.
    pub id: String,
    pub name: String,
    pub config: WallpaperConfig,
    /// Whether applying it also moves Live Earth to its place, which can be someone's own location.
    pub includes_place: bool,
}

/// A fresh UUID in Swift's uppercase form.
pub fn new_id() -> String {
    let g = windows::core::GUID::new().unwrap_or_else(|_| {
        // only if COM can't make one: the clock is unique enough for a list kept on one machine
        let n = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        windows::core::GUID::from_u128(n)
    });
    format!(
        "{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        g.data1, g.data2, g.data3, g.data4[0], g.data4[1], g.data4[2], g.data4[3], g.data4[4], g.data4[5], g.data4[6], g.data4[7]
    )
}

impl WallpaperConfig {
    /// `self` at `other`'s place for Live Earth. Presets and preset files leave the place out
    /// unless asked: it can be where someone is.
    pub fn with_place_of(&self, other: &WallpaperConfig) -> WallpaperConfig {
        let mut c = self.clone();
        c.home_latitude = other.home_latitude;
        c.home_longitude = other.home_longitude;
        c.home_from_device = other.home_from_device;
        c
    }

    /// `self` with the active scene's own image entry brought up to date. That entry is only
    /// written as the scene is left, so until then it can hold an older copy nothing reads, which
    /// shouldn't make two configs with the same settings compare different.
    pub fn with_own_image_current(&self) -> WallpaperConfig {
        let mut c = self.clone();
        if c.has_own_image(c.scene) {
            let img = c.image();
            c.scene_image.insert(c.scene.raw().to_string(), img);
        }
        c
    }
}

impl UserPreset {
    pub fn new(name: &str, config: WallpaperConfig) -> UserPreset {
        UserPreset { id: new_id(), name: name.to_string(), config, includes_place: false }
    }

    /// `config` with the machine's own settings taken from `current`.
    pub fn applied(&self, current: &WallpaperConfig) -> WallpaperConfig {
        let mut c = if self.includes_place { self.config.clone() } else { self.config.with_place_of(current) };
        c.fps = current.fps;
        c.lock_screen_still = current.lock_screen_still;
        c.lock_screen_smooth = current.lock_screen_smooth;
        c.phone_framing = None;
        c.sanitized()
    }

    /// Whether `current` is this preset's look, so the menus show it as the current one.
    pub fn matches(&self, current: &WallpaperConfig) -> bool {
        self.applied(current).with_own_image_current() == current.with_own_image_current()
    }

    /// Reads one from a saved list entry or a `.deepfield` file, through the config's lenient
    /// decoder, so one saved by an older or newer version still loads.
    pub fn from_json(dict: &Map<String, Value>) -> Option<UserPreset> {
        let mut config = WallpaperConfig::decode(&dict.get("config")?.to_string())?;
        // a file never makes someone else's computer use its location
        if dict.contains_key("format") {
            config.home_from_device = false;
        }
        let name = dict.get("name").and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or("Imported");
        let id = dict.get("id").and_then(Value::as_str).map(str::to_string).unwrap_or_else(new_id);
        let includes_place = dict.get("includesPlace").and_then(Value::as_bool).unwrap_or(false);
        Some(UserPreset { id, name: name.to_string(), config, includes_place })
    }

    /// A `.deepfield` file. Without `include_place` it holds the default place; with it, the place
    /// is a fixed one, since following the device would mean someone else's.
    pub fn file_data(&self, include_place: bool) -> String {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct PresetFile<'a> {
            format: &'static str,
            version: i32,
            name: &'a str,
            config: WallpaperConfig,
            includes_place: bool,
        }
        let mut config =
            if include_place { self.config.clone() } else { self.config.with_place_of(&WallpaperConfig::default()) };
        config.home_from_device = false;
        let file = PresetFile { format: "deep-field-preset", version: 1, name: &self.name, config, includes_place: include_place };
        // through a Value, whose maps are sorted, as the Mac writes with .sortedKeys
        let value = serde_json::to_value(&file).unwrap_or(Value::Null);
        serde_json::to_string_pretty(&value).unwrap_or_default()
    }
}

/// Reads a `.deepfield` (or JSON) file as a preset.
pub fn read_file(path: &Path) -> Result<UserPreset, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("can't read {}: {e}", path.display()))?;
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(d)) => UserPreset::from_json(&d),
        _ => None,
    }
    .ok_or(format!("{} isn't a Deep Field preset", path.display()))
}

fn same_name(a: &str, b: &str) -> bool {
    a.trim().to_lowercase() == b.trim().to_lowercase()
}

/// The user's presets, read from and written to presets.json on every change, so the wallpaper's
/// tray menu and the Customize window see each other's edits.
pub struct PresetStore {
    pub presets: Vec<UserPreset>,
    path: PathBuf,
    modified: Option<SystemTime>,
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

impl PresetStore {
    pub fn load() -> PresetStore {
        Self::at(dir().join("presets.json"))
    }

    pub fn at(path: PathBuf) -> PresetStore {
        let mut s = PresetStore { presets: Vec::new(), path, modified: None };
        s.read();
        s
    }

    fn read(&mut self) {
        self.modified = mtime(&self.path);
        let list = std::fs::read_to_string(&self.path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok());
        // one by one, so a bad entry is dropped alone
        self.presets = match list {
            Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_object().and_then(UserPreset::from_json)).collect(),
            _ => Vec::new(),
        };
    }

    /// Picks up changes another program made; true when the list changed.
    pub fn reload_if_changed(&mut self) -> bool {
        if mtime(&self.path) == self.modified {
            return false;
        }
        let before = self.presets.clone();
        self.read();
        self.presets != before
    }

    /// Written beside the real file and renamed into place, so a reader never sees half of it.
    fn save(&mut self) {
        let _ = std::fs::create_dir_all(self.path.parent().unwrap_or(Path::new(".")));
        let Ok(text) = serde_json::to_string_pretty(&self.presets) else { return };
        let tmp = self.path.with_extension("json.tmp");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
        self.modified = mtime(&self.path);
    }

    /// Saves `config` under `name`, replacing a preset of the same name (which keeps its place
    /// option unless `include_place` is given).
    pub fn save_current(&mut self, name: &str, config: &WallpaperConfig, include_place: Option<bool>) -> UserPreset {
        let trimmed = name.trim();
        let mut p = UserPreset::new(if trimmed.is_empty() { "Untitled" } else { trimmed }, config.clone());
        p.includes_place = include_place.unwrap_or(false);
        if let Some(i) = self.presets.iter().position(|q| same_name(&q.name, &p.name)) {
            p.id = self.presets[i].id.clone();
            p.includes_place = include_place.unwrap_or(self.presets[i].includes_place);
            self.presets[i] = p.clone();
        } else {
            self.presets.push(p.clone());
        }
        self.save();
        p
    }

    /// The preset keeps the place it was saved with either way, so this can be switched back.
    pub fn set_includes_place(&mut self, id: &str, on: bool) {
        if let Some(p) = self.presets.iter_mut().find(|p| p.id == id) {
            p.includes_place = on;
            self.save();
        }
    }

    pub fn delete(&mut self, id: &str) {
        self.presets.retain(|p| p.id != id);
        self.save();
    }

    /// False, changing nothing, when the name is empty or another preset has it.
    pub fn rename(&mut self, id: &str, name: &str) -> bool {
        let trimmed = name.trim();
        if trimmed.is_empty() || self.named(trimmed).is_some_and(|o| o.id != id) {
            return false;
        }
        let Some(p) = self.presets.iter_mut().find(|p| p.id == id) else { return false };
        p.name = trimmed.to_string();
        self.save();
        true
    }

    /// The preset called `name`, ignoring case and surrounding space.
    pub fn named(&self, name: &str) -> Option<&UserPreset> {
        self.presets.iter().find(|p| same_name(&p.name, name))
    }

    pub fn by_id(&self, id: &str) -> Option<&UserPreset> {
        self.presets.iter().find(|p| p.id == id)
    }

    /// `base`, with a number if a preset already has it.
    pub fn unused_name(&self, base: &str) -> String {
        let mut name = base.to_string();
        let mut n = 2;
        while self.named(&name).is_some() {
            name = format!("{base} {n}");
            n += 1;
        }
        name
    }

    /// The preset `config` matches, if any.
    pub fn current(&self, config: &WallpaperConfig) -> Option<&UserPreset> {
        self.presets.iter().find(|p| p.matches(config))
    }

    /// Reads a `.deepfield` file and adds it (a name already in use gets a number).
    pub fn import_file(&mut self, path: &Path) -> Result<UserPreset, String> {
        let mut p = read_file(path)?;
        p.id = new_id();
        p.name = self.unused_name(&p.name);
        self.presets.push(p.clone());
        self.save();
        Ok(p)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::SceneKind;

    #[test]
    fn presets_keep_the_machines_own_settings() {
        let mut look = WallpaperConfig::default();
        look.set_scene(SceneKind::Comet);
        look.tilt = 17.0;
        look.home_latitude = 51.5;
        look.fps = 60;
        let p = UserPreset::new("p", look.clone());
        let mut now = WallpaperConfig::default();
        now.fps = 30;
        now.home_latitude = -33.9;
        let a = p.applied(&now);
        assert_eq!((a.scene, a.tilt, a.fps, a.home_latitude), (SceneKind::Comet, 17.0, 30, -33.9));
        assert!(p.matches(&a));
        let mut with_place = p.clone();
        with_place.includes_place = true;
        assert_eq!(with_place.applied(&now).home_latitude, 51.5);
    }

    #[test]
    fn own_image_settings_compare_as_they_are() {
        // the active scene's own image entry is stale until the scene is left
        let mut c = WallpaperConfig::default();
        c.scene_image.insert(c.scene.raw().into(), c.image());
        c.shared_image = Some(c.image());
        let p = UserPreset::new("p", c.clone());
        c.bloom = 1.0;
        assert!(!p.matches(&c));
        let p = UserPreset::new("q", c.clone());
        assert!(p.matches(&c));
    }

    #[test]
    fn files_round_trip_and_leave_the_place_out() {
        let mut c = WallpaperConfig::default();
        c.set_scene(SceneKind::LiveEarth);
        c.home_latitude = 51.5;
        c.home_from_device = true;
        let p = UserPreset::new("Home", c);
        let text = p.file_data(false);
        assert!(text.contains("\"format\": \"deep-field-preset\""));
        let Value::Object(d) = serde_json::from_str(&text).unwrap() else { panic!() };
        let back = UserPreset::from_json(&d).unwrap();
        assert_eq!(back.name, "Home");
        assert_eq!(back.config.home_latitude, WallpaperConfig::default().home_latitude);
        assert!(!back.config.home_from_device && !back.includes_place);
        let Value::Object(d) = serde_json::from_str(&p.file_data(true)).unwrap() else { panic!() };
        let back = UserPreset::from_json(&d).unwrap();
        assert!(back.includes_place && back.config.home_latitude == 51.5 && !back.config.home_from_device);
    }

    #[test]
    fn the_store_names_and_saves() {
        let path = std::env::temp_dir().join(format!("deepfield-presets-{}.json", new_id()));
        let mut s = PresetStore::at(path.clone());
        let c = WallpaperConfig::default();
        let a = s.save_current("  Night ", &c, Some(true));
        assert_eq!(a.name, "Night");
        // the same name, any case, replaces it and keeps its id and place option
        let b = s.save_current("night", &c, None);
        assert_eq!((s.presets.len(), b.id.clone(), b.includes_place), (1, a.id.clone(), true));
        assert_eq!(s.unused_name("Night"), "Night 2");
        s.save_current("Day", &c, None);
        assert!(!s.rename(&a.id, "DAY") && !s.rename(&a.id, " ") && s.rename(&a.id, "Dusk"));
        // a second store sees it all
        let other = PresetStore::at(path.clone());
        assert_eq!(other.presets, s.presets);
        assert_eq!(other.current(&c).map(|p| p.name.as_str()), Some("Dusk"));
        s.delete(&a.id);
        assert_eq!(PresetStore::at(path.clone()).presets.len(), 1);
        let _ = std::fs::remove_file(path);
    }
}
