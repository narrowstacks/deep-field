//! The window's colors and sizes, after the Mac's Theme.swift: dark in both system appearances,
//! since colors are judged against a black sky. The Mac takes the system's dark colors; these are
//! the same values, with its coral accent.

use gpui_kit::component::{Theme, ThemeMode};
use gpui_kit::*;

pub const WINDOW_W: f32 = 1160.0;
pub const WINDOW_H: f32 = 760.0;
pub const MIN_W: f32 = 1100.0;
pub const MIN_H: f32 = 600.0;
pub const INSPECTOR_W: f32 = 440.0;
pub const STAGE_PAD_X: f32 = 20.0;
pub const STAGE_PAD_Y: f32 = 16.0;
pub const PREVIEW_BOX: (f32, f32) = (680.0, 425.0);
pub const CAPTION_H: f32 = 30.0;

pub fn hex(v: u32) -> Hsla {
    gpui_kit::rgb(v).into()
}

pub fn white(alpha: f32) -> Hsla {
    hsla(0.0, 0.0, 1.0, alpha)
}

/// underPageBackgroundColor (the stage behind the preview)
pub fn stage_bg() -> Hsla {
    hex(0x1e1e1e)
}
/// windowBackgroundColor (the inspector)
pub fn inspector_bg() -> Hsla {
    hex(0x2a2a2a)
}
/// a grouped form's box
pub fn group_bg() -> Hsla {
    hex(0x323232)
}
pub fn text() -> Hsla {
    white(0.88)
}
pub fn secondary() -> Hsla {
    white(0.55)
}
/// the accent the Mac window shows (sliders, selection, switches)
pub fn accent() -> Hsla {
    hex(0xe5534b)
}
/// a problem with what was typed (the Mac's system orange)
pub fn warning() -> Hsla {
    hex(0xff9f0a)
}
pub fn control_bg() -> Hsla {
    white(0.09)
}
pub fn control_selected() -> Hsla {
    white(0.24)
}

pub const MONO: &str = "Cascadia Mono";

pub fn apply(cx: &mut App) {
    Theme::change(ThemeMode::Dark, None, cx);
    Theme::update(cx, |t| {
        t.font_family = "Segoe UI".into();
        t.font_size = px(13.0);
        t.radius = px(5.0);
        t.radius_lg = px(8.0);
        t.shadow = false;
        t.focus_ring = false;
        t.background = inspector_bg();
        t.foreground = text();
        t.border = white(0.14);
        t.input = white(0.14);
        t.muted_foreground = secondary();
        t.primary = accent();
        t.primary_hover = hex(0xee6a62);
        t.primary_active = hex(0xc9443d);
        t.primary_foreground = hex(0xffffff);
        t.accent = white(0.1);
        t.accent_foreground = text();
        t.secondary = white(0.1);
        t.secondary_hover = white(0.16);
        t.secondary_active = white(0.2);
        t.secondary_foreground = text();
        t.popover = hex(0x2f2f2f);
        t.popover_foreground = text();
        t.ring = accent();
        t.slider_bar = accent();
        t.slider_thumb = hex(0xffffff);
        t.switch = white(0.18);
        t.switch_thumb = hex(0xffffff);
        t.selection = accent().opacity(0.35);
        t.caret = accent();
    });
}

/// The window icon: the tray icon's small black hole, a dark shadow inside a warm ring.
pub fn icon() -> image::RgbaImage {
    const N: u32 = 64;
    let mut rgba = Vec::with_capacity((N * N * 4) as usize);
    for y in 0..N {
        for x in 0..N {
            let dx = (x as f32 + 0.5 - N as f32 / 2.0) / (N as f32 / 2.0);
            let dy = (y as f32 + 0.5 - N as f32 / 2.0) / (N as f32 / 2.0);
            let r = (dx * dx + dy * dy).sqrt();
            let ring = (-((r - 0.62) / 0.16).powi(2)).exp();
            let disk = (-(dy / 0.12).powi(2)).exp() * (r < 1.0) as i32 as f32 * (r > 0.45) as i32 as f32;
            let side = 0.7 + 0.3 * (-dx);
            let v = ((ring + 0.8 * disk) * side).min(1.0);
            let a = if r < 0.42 { 1.0 } else { v };
            rgba.extend_from_slice(&[(255.0 * v) as u8, (170.0 * v) as u8, (70.0 * v) as u8, (255.0 * a) as u8]);
        }
    }
    image::RgbaImage::from_raw(N, N, rgba).expect("icon")
}
