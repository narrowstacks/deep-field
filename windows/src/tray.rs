//! The notification-area icon and its menu, the Windows stand-in for the macOS menu bar item.

use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::config::{SceneKind, WallpaperConfig};

pub enum TrayAction {
    Scene(SceneKind),
    PixelSize(i64),
    TogglePause,
    EditSettings,
    Quit,
}

const PIXEL_SIZES: [i64; 5] = [1, 2, 3, 4, 6];

pub struct Tray {
    _icon: TrayIcon,
    scenes: Vec<(SceneKind, CheckMenuItem)>,
    sizes: Vec<(i64, CheckMenuItem)>,
    pause: MenuItem,
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
        let pause = MenuItem::new("Pause", true, None);
        let edit = MenuItem::new("Edit Settings...", true, None);
        let quit = MenuItem::new("Quit Deep Field", true, None);
        let _ = menu.append_items(&[&scene_menu, &size_menu, &PredefinedMenuItem::separator(), &pause, &edit,
                                    &PredefinedMenuItem::separator(), &quit]);
        let icon = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_tooltip("Deep Field")
            .with_icon(icon())
            .build()
            .expect("tray icon");
        Tray { _icon: icon, scenes, sizes, edit: edit.id().clone(), quit: quit.id().clone(), pause }
    }

    pub fn poll(&self) -> Option<TrayAction> {
        let ev = MenuEvent::receiver().try_recv().ok()?;
        let id = ev.id;
        if let Some((s, _)) = self.scenes.iter().find(|(_, i)| *i.id() == id) {
            return Some(TrayAction::Scene(*s));
        }
        if let Some((n, _)) = self.sizes.iter().find(|(_, i)| *i.id() == id) {
            return Some(TrayAction::PixelSize(*n));
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
        self.pause.set_text(if paused { "Resume" } else { "Pause" });
    }
}

/// Opens a file with its default app (the settings JSON in a text editor).
pub fn open(path: &std::ffi::OsStr) {
    let _ = std::process::Command::new("cmd").arg("/C").arg("start").arg("").arg(path).spawn();
}
