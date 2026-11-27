//! The notification-area icon and its menu, the Windows stand-in for the macOS menu bar item.

use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::config::{SceneKind, WallpaperConfig};

pub enum TrayAction {
    /// Show on Desktop: the scene behind the icons, or the desktop picture back
    ToggleWallpaper,
    Customize,
    Scene(SceneKind),
    /// a saved preset, by id
    Preset(String),
    /// asks the Customize window to save, import or export (see `customize_request`)
    Request(&'static str),
    /// turns the schedule on or off (or, with nothing in it yet, opens it in Customize)
    ToggleSchedule,
    /// the schedule's next entry now
    SkipSchedule,
    PixelSize(i64),
    TogglePause,
    EditSettings,
    Quit,
}

use crate::config::PIXEL_SIZES;

pub struct Tray {
    _icon: TrayIcon,
    scenes: Vec<(SceneKind, CheckMenuItem)>,
    sizes: Vec<(i64, CheckMenuItem)>,
    pause: MenuItem,
    presets_menu: Submenu,
    presets: Vec<(String, CheckMenuItem)>,
    requests: Vec<(&'static str, MenuItem)>,
    menu: Menu,
    schedule: CheckMenuItem,
    skip: MenuItem,
    skip_shown: bool,
    wallpaper: CheckMenuItem,
    guide: MenuId,
    customize: MenuId,
    edit: MenuId,
    quit: MenuId,
}

/// A small black hole: a dark shadow inside a warm ring, brighter on its approaching side.
fn icon() -> Icon {
    const N: u32 = 32;
    let mut rgba = Vec::with_capacity((N * N * 4) as usize);
    for y in 0..N {
        for x in 0..N {
            let dx = (x as f32 + 0.5 - N as f32 / 2.0) / (N as f32 / 2.0);
            let dy = (y as f32 + 0.5 - N as f32 / 2.0) / (N as f32 / 2.0);
            let r = (dx * dx + dy * dy).sqrt();
            let ring = (-((r - 0.62) / 0.16).powi(2)).exp();
            let disk = (-(dy / 0.12).powi(2)).exp() * (r < 1.0) as i32 as f32 * (r > 0.45) as i32 as f32;
            let side = 0.7 + 0.3 * (-dx);
            let v = (ring + 0.8 * disk) * side;
            let a = if r < 0.42 { 1.0 } else { v.min(1.0) };
            rgba.extend_from_slice(&[(255.0 * v.min(1.0)) as u8, (170.0 * v.min(1.0)) as u8, (70.0 * v.min(1.0)) as u8, (255.0 * a) as u8]);
        }
    }
    Icon::from_rgba(rgba, N, N).expect("tray icon")
}

impl Tray {
    pub fn new(c: &WallpaperConfig) -> Tray {
        let menu = Menu::new();
        let scene_menu = Submenu::new("Scene", true);
        let scenes: Vec<_> = SceneKind::all()
            .iter()
            .copied()
            .filter(|s| s.is_ported())
            .map(|s| (s, CheckMenuItem::new(s.title(), true, s == c.scene, None)))
            .collect();
        for (_, item) in &scenes {
            let _ = scene_menu.append(item);
        }
        let size_menu = Submenu::new("Pixel Size", true);
        let sizes: Vec<_> = PIXEL_SIZES
            .iter()
            .map(|&n| (n, CheckMenuItem::new(format!("{n} px"), true, n == c.pixel_size as i64, None)))
            .collect();
        for (_, item) in &sizes {
            let _ = size_menu.append(item);
        }
        let presets_menu = Submenu::new("Presets", true);
        let schedule = CheckMenuItem::new("Change on Schedule", true, false, None);
        let skip = MenuItem::new("Next in Schedule", true, None);
        let wallpaper = CheckMenuItem::new("Show on Desktop", true, true, None);
        let customize = MenuItem::new("Customize...", true, None);
        let pause = MenuItem::new("Pause Animation", true, None);
        let guide = MenuItem::new("Welcome Guide...", true, None);
        let edit = MenuItem::new("Edit Settings File...", true, None);
        let quit = MenuItem::new("Quit Deep Field", true, None);
        // the Mac's order, with the scene and pixel size submenus it doesn't have after Customize
        let _ = menu.append_items(&[&wallpaper, &pause, &customize, &PredefinedMenuItem::separator(), &scene_menu,
                                    &presets_menu, &schedule, &size_menu,
                                    &PredefinedMenuItem::separator(), &guide, &edit,
                                    &PredefinedMenuItem::separator(), &quit]);
        let icon = TrayIconBuilder::new()
            .with_menu(Box::new(menu.clone()))
            .with_tooltip("Deep Field")
            .with_icon(icon())
            .build()
            .expect("tray icon");
        let mut tray = Tray {
            _icon: icon, scenes, sizes, presets_menu, presets: Vec::new(), requests: Vec::new(), menu, schedule, skip,
            skip_shown: false, wallpaper, guide: guide.id().clone(),
            customize: customize.id().clone(), edit: edit.id().clone(),
            quit: quit.id().clone(), pause,
        };
        tray.set_presets(&crate::presets::PresetStore::load(), c);
        tray
    }

    pub fn poll(&self) -> Option<TrayAction> {
        let ev = MenuEvent::receiver().try_recv().ok()?;
        let id = ev.id;
        if id == *self.wallpaper.id() {
            return Some(TrayAction::ToggleWallpaper);
        }
        if id == self.customize {
            return Some(TrayAction::Customize);
        }
        if id == self.guide {
            return Some(TrayAction::Request("welcome"));
        }
        if let Some((s, _)) = self.scenes.iter().find(|(_, i)| *i.id() == id) {
            return Some(TrayAction::Scene(*s));
        }
        if let Some((p, _)) = self.presets.iter().find(|(_, i)| *i.id() == id) {
            return Some(TrayAction::Preset(p.clone()));
        }
        if let Some((r, _)) = self.requests.iter().find(|(_, i)| *i.id() == id) {
            return Some(TrayAction::Request(r));
        }
        if let Some((n, _)) = self.sizes.iter().find(|(_, i)| *i.id() == id) {
            return Some(TrayAction::PixelSize(*n));
        }
        if id == *self.schedule.id() {
            return Some(TrayAction::ToggleSchedule);
        }
        if id == *self.skip.id() {
            return Some(TrayAction::SkipSchedule);
        }
        if id == *self.pause.id() {
            return Some(TrayAction::TogglePause);
        }
        if id == self.edit {
            return Some(TrayAction::EditSettings);
        }
        if id == self.quit {
            return Some(TrayAction::Quit);
        }
        None
    }

    /// Check marks follow the config (a click toggles a check item on its own).
    pub fn update(&self, c: &WallpaperConfig, paused: bool) {
        for (s, item) in &self.scenes {
            item.set_checked(*s == c.scene);
        }
        for (n, item) in &self.sizes {
            item.set_checked(*n == c.pixel_size as i64);
        }
        self.pause.set_text(if paused { "Resume Animation" } else { "Pause Animation" });
    }

    /// Show on Desktop's check, and Pause, which has nothing to pause with the scene off the
    /// desktop (the Mac hides it; a tray menu item can only be greyed out).
    pub fn update_desktop(&self, on: bool) {
        self.wallpaper.set_checked(on);
        self.pause.set_enabled(on);
    }

    /// Rebuilds the Presets submenu as the Mac's menu bar has it: each preset, checked when it's
    /// the current look, then saving, importing and exporting.
    pub fn set_presets(&mut self, store: &crate::presets::PresetStore, c: &WallpaperConfig) {
        while self.presets_menu.remove_at(0).is_some() {}
        let current = store.current(c).map(|p| p.id.clone());
        self.presets = store
            .presets
            .iter()
            .map(|p| (p.id.clone(), CheckMenuItem::new(&p.name, true, current.as_ref() == Some(&p.id), None)))
            .collect();
        if self.presets.is_empty() {
            let _ = self.presets_menu.append(&MenuItem::new("No saved presets yet", false, None));
        }
        for (_, item) in &self.presets {
            let _ = self.presets_menu.append(item);
        }
        let _ = self.presets_menu.append(&PredefinedMenuItem::separator());
        self.requests = [("save-preset", "Save Current Settings as Preset..."), ("import-preset", "Import Preset..."),
                         ("export-preset", "Export Current Settings...")]
            .into_iter()
            .map(|(r, title)| (r, MenuItem::new(title, true, None)))
            .collect();
        for (_, item) in &self.requests {
            let _ = self.presets_menu.append(item);
        }
    }


    /// The schedule items as the Mac's menu has them: with nothing scheduled yet the toggle
    /// opens Customize to set it up, and Next shows only while a rotation of two or more runs.
    pub fn update_schedule(&mut self, s: &crate::schedule::WallpaperSchedule) {
        self.schedule.set_checked(s.enabled);
        self.schedule.set_text(if s.entries.is_empty() { "Set Up Schedule..." } else { "Change on Schedule" });
        let show = s.enabled && s.mode == crate::schedule::Mode::Rotate && s.entries.len() > 1;
        if show != self.skip_shown {
            if show {
                // just below the toggle: Show on Desktop, Pause, Customize, separator, Scene,
                // Presets, the toggle
                let _ = self.menu.insert(&self.skip, 7);
            } else {
                let _ = self.menu.remove(&self.skip);
            }
            self.skip_shown = show;
        }
    }

    /// Moves the preset check mark to the current look.
    pub fn update_presets(&self, store: &crate::presets::PresetStore, c: &WallpaperConfig) {
        let current = store.current(c).map(|p| p.id.clone());
        for (id, item) in &self.presets {
            item.set_checked(current.as_ref() == Some(id));
        }
    }
}

/// Where the tray asks the Customize window to open one of its preset dialogs, or the Schedule
/// section to set one up: the request's name, read and removed by the window within half a
/// second, whether it was open already or is just starting.
pub fn customize_request_path() -> std::path::PathBuf {
    crate::config_store::dir().join("customize-request")
}

/// Opens the Customize window with one of its preset dialogs, its Schedule section or the
/// welcome guide showing.
pub fn request_customize(request: &str) {
    let _ = std::fs::create_dir_all(crate::config_store::dir());
    let _ = std::fs::write(customize_request_path(), request);
    open_customize();
}

/// Opens the Customize window, deepfield-settings.exe. A packaged build puts it beside this
/// program; while developing it's in the settings crate's own target folder
/// (windows\settings\target\<profile>, next to windows\target\<profile>). A second launch only
/// brings the open window forward.
pub fn open_customize() {
    let found = std::env::current_exe().ok().and_then(|exe| {
        let dir = exe.parent()?.to_path_buf();
        let beside = dir.join("deepfield-settings.exe");
        if beside.exists() {
            return Some(beside);
        }
        let profile = dir.file_name()?.to_owned();
        let dev = dir.join("..").join("..").join("settings").join("target").join(profile).join("deepfield-settings.exe");
        let release = dir.join(r"..\..\settings\target\release\deepfield-settings.exe");
        [dev, release].into_iter().find(|p| p.exists())
    });
    match found {
        Some(exe) => {
            if let Err(e) = std::process::Command::new(&exe).spawn() {
                crate::error_box(&format!("Could not open {}: {e}", exe.display()));
            }
        }
        None => crate::error_box(
            "The Customize window (deepfield-settings.exe) wasn't found next to Deep Field. Build it with \
             `cargo build --release` in windows\\settings, or edit the settings file from this menu.",
        ),
    }
}

/// Opens a file with its default app (the settings JSON in a text editor).
pub fn open(path: &std::ffi::OsStr) {
    let _ = std::process::Command::new("cmd").arg("/C").arg("start").arg("").arg(path).spawn();
}
