//! The welcome guide (UI/WelcomeView.swift): four steps beside a large live preview. Shown on a
//! first launch, and from the tray's Welcome Guide item. The desktop stays as it was until the
//! last step's Set as Wallpaper, so nothing changes under someone who only opened the app to
//! look. Opened again later, with the scene already on the desktop, its changes show there as
//! they're made, and it says so.
//!
//! It's a mode of the Customize window rather than a window of its own, so the two share one
//! preview renderer and one copy of the settings: the window takes the guide's size and title,
//! and goes back to Customize after (or closes, when it was opened for the guide alone).

use deepfield::app_state::{self, AppState};
use deepfield::config::WallpaperConfig;
use deepfield::tweaks::{self, Tweak};
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::{Disableable, Icon, IconName, Sizable};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;

use crate::app::Settings;
use crate::system;
use crate::theme;

pub const PREVIEW_BOX: (f32, f32) = (800.0, 500.0);
const PANEL_W: f32 = 330.0;
const PAD: f32 = 24.0;
pub const WINDOW: (f32, f32) = (PREVIEW_BOX.0 + 2.0 * PAD + 1.0 + PANEL_W + 2.0 * PAD, 640.0);
/// Two columns of thumbnails across the panel.
pub const GALLERY_BOX: ((f32, f32), usize) = ((158.0, 99.0), 2);
pub const STEPS: usize = 4;

pub struct Guide {
    pub step: usize,
    /// the settings as the guide opened, which the tweaks undo to
    base: WallpaperConfig,
    /// the scene was already on the desktop as the guide opened
    on_desktop: bool,
    launch_at_login: bool,
    /// The lock screen choice, if one was made. It replaces the lock screen picture, so it waits
    /// for the last step's button.
    lock_screen_choice: Option<bool>,
    /// The window opened for the guide alone, so finishing closes it; otherwise it goes back to
    /// Customize at the size it had.
    alone: bool,
    customize_size: Size<Pixels>,
}

/// Symbols from Segoe UI Symbol standing in for the Mac's SF Symbols.
fn symbol(id: &str) -> &'static str {
    match id {
        "chunky" => "\u{25a6}",
        "smooth" => "\u{25cd}",
        "retro" => "\u{25a9}",
        "glow" => "\u{2726}",
        "vivid" => "\u{25d5}",
        "moody" => "\u{25d0}",
        _ => "\u{2605}",
    }
}

impl Settings {
    /// Opens the guide at its first step (WelcomeWindowController.show).
    pub fn open_guide(&mut self, alone: bool, window: &mut Window, cx: &mut Context<Self>) {
        AppState::update(|s| s.welcome_shown = true);
        if self.guide.is_none() {
            self.flush();
            let on_desktop = AppState::load().wallpaper_enabled && app_state::wallpaper_running();
            self.guide = Some(Guide {
                step: 0,
                base: self.store.config.clone(),
                on_desktop,
                launch_at_login: self.login_item,
                lock_screen_choice: None,
                alone,
                customize_size: window.bounds().size,
            });
            window.set_window_title(system::WELCOME_TITLE);
            if !alone {
                window.resize(size(px(WINDOW.0), px(WINDOW.1)));
            }
            self.thumbs_due = Some(std::time::Instant::now());
        }
        window.activate_window();
        cx.notify();
    }

    fn guide_move(&mut self, by: isize, cx: &mut Context<Self>) {
        if let Some(g) = &mut self.guide {
            g.step = (g.step as isize + by).clamp(0, STEPS as isize - 1) as usize;
        }
        cx.notify();
    }

    fn guide_done(&mut self, set_wallpaper: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(g) = self.guide.take() else { return };
        if set_wallpaper {
            if g.launch_at_login != self.login_item {
                if let Err(e) = system::set_login_item(g.launch_at_login) {
                    self.flash(format!("Couldn't change the startup setting: {e}"));
                }
                self.login_item = system::login_item().is_some();
            }
            if let Some(on) = g.lock_screen_choice {
                self.edit(cx, |c| c.lock_screen_still = on);
            }
        }
        self.flush();
        // Done leaves Show on Desktop as it is, in case it was switched off meanwhile
        if set_wallpaper && !g.on_desktop {
            AppState::update(|s| s.wallpaper_enabled = true);
            if !app_state::wallpaper_running() {
                match system::wallpaper_exe() {
                    Some(exe) => {
                        if let Err(e) = std::process::Command::new(&exe).spawn() {
                            deepfield::error_box(&format!("Could not start {}: {e}", exe.display()));
                        }
                    }
                    None => deepfield::error_box("deepfield-wallpaper.exe wasn't found next to this program."),
                }
            }
        }
        if g.alone {
            window.remove_window();
            return;
        }
        window.set_window_title(system::WINDOW_TITLE);
        window.resize(g.customize_size);
        self.thumbs_due = Some(std::time::Instant::now());
        cx.notify();
    }

    pub fn render_guide(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let Some(g) = &self.guide else { return div().into_any_element() };
        let step = g.step;
        let fitted = self.preview_fitted(window);
        let title = self.store.config.scene.title();
        let preview = div()
            .w(px(fitted.0))
            .h(px(fitted.1))
            .bg(gpui_kit::black())
            .rounded(px(6.0))
            .border_1()
            .border_color(theme::white(0.14))
            .overflow_hidden()
            .when_some(self.preview.clone(), |d, image| d.child(img(image).w(px(fitted.0 - 2.0)).h(px(fitted.1 - 2.0))))
            .when_some(self.preview_error.clone(), |d, e| {
                d.child(div().p_4().text_color(theme::secondary()).child(format!("The preview couldn't start: {e}")))
            });
        let stage = div()
            .w(px(PREVIEW_BOX.0 + 2.0 * PAD))
            .h_full()
            .flex_none()
            .p(px(PAD))
            .bg(theme::stage_bg())
            // the preview and its caption sit in the middle of the column, however short a wide
            // screen makes the preview
            .flex()
            .flex_col()
            .justify_center()
            .gap(px(10.0))
            .child(div().w(px(PREVIEW_BOX.0)).flex().justify_center().child(preview))
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(theme::secondary())
                    .child(format!("Live preview of {title}, as it will look on your desktop")),
            );

        let body = match step {
            0 => self.guide_hello(),
            1 => self.guide_scene(cx),
            2 => self.guide_tweaks(cx),
            _ => self.guide_finish(cx),
        };
        let panel = div()
            .flex_1()
            .h_full()
            .min_w(px(0.0))
            .px(px(PAD))
            .pt(px(PAD))
            .bg(theme::inspector_bg())
            .border_l_1()
            .border_color(theme::white(0.08))
            .flex()
            .flex_col()
            .child(step_dots(step).mb(px(18.0)))
            .child(div().flex_1().min_h(px(0.0)).overflow_hidden().flex().flex_col().child(body))
            .child(self.guide_navigation(window, cx));
        div().size_full().flex().flex_row().child(stage).child(panel).into_any_element()
    }

    fn guide_hello(&self) -> AnyElement {
        let on_desktop = self.guide.as_ref().is_some_and(|g| g.on_desktop);
        div()
            .flex()
            .flex_col()
            .gap(px(14.0))
            .child(div().text_size(px(24.0)).font_weight(FontWeight::SEMIBOLD).child("Welcome to Deep Field"))
            .child(
                "Deep Field puts a moving space scene behind your windows: black holes, galaxies, auroras, ringed \
                 planets and more, drawn as dithered pixel art.",
            )
            .child(div().text_color(theme::secondary()).child(if on_desktop {
                "Take a minute to pick a scene and try a few looks. Changes show on your desktop as you make them."
            } else {
                "Your desktop stays as it is for now. Take a minute to pick a scene and try a few looks, and set it \
                 as your wallpaper at the end if you like it."
            }))
            .child(
                div()
                    .pt(px(4.0))
                    .text_color(theme::secondary())
                    .child("Afterwards, Deep Field lives in the notification area, by the clock."),
            )
            .into_any_element()
    }

    fn guide_scene(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let blurb = crate::model::blurb(self.store.config.scene);
        div()
            .flex_1()
            .min_h(px(0.0))
            .flex()
            .flex_col()
            .gap(px(10.0))
            .child(heading("Pick a scene"))
            .child(div().min_h(px(36.0)).text_size(px(12.0)).text_color(theme::secondary()).child(blurb))
            .child(
                div()
                    .id("guide-gallery")
                    .flex_1()
                    .min_h(px(0.0))
                    .overflow_y_scroll()
                    .child(self.render_gallery(GALLERY_BOX.1, cx)),
            )
            .into_any_element()
    }

    fn guide_tweaks(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let c = self.store.config.clone();
        let Some(base) = self.guide.as_ref().map(|g| g.base.clone()) else { return div().into_any_element() };
        let rows: Vec<_> = tweaks::offered(c.scene).into_iter().map(|t| self.tweak_row(t, (t.is_on)(&c), cx)).collect();
        let undone = tweaks::undoing_all(&c, &base);
        let can_undo = undone != c;
        let undo = Button::new("undo-all")
            .label("Undo All")
            .small()
            .disabled(!can_undo)
            .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| {
                let undone = undone.clone();
                this.edit(cx, |c| *c = undone);
            }));
        div()
            .flex_1()
            .min_h(px(0.0))
            .flex()
            .flex_col()
            .gap(px(10.0))
            .child(heading("Try a few looks"))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(theme::secondary())
                    .child("Click to turn each one on or off and watch the preview. There are many more settings in Customize."),
            )
            .child(
                div()
                    .id("guide-tweaks")
                    .flex_1()
                    .min_h(px(0.0))
                    .overflow_y_scroll()
                    .child(div().py(px(2.0)).flex().flex_col().gap(px(8.0)).children(rows)),
            )
            .child(div().flex().child(undo))
            .into_any_element()
    }

    fn tweak_row(&mut self, t: &'static Tweak, on: bool, cx: &mut Context<Self>) -> AnyElement {
        let tint = if on { theme::accent() } else { theme::secondary() };
        let mark = if on {
            Icon::new(IconName::CircleCheck).text_color(theme::accent()).into_any_element()
        } else {
            div().size(px(14.0)).rounded_full().border_1().border_color(theme::secondary()).into_any_element()
        };
        div()
            .id(SharedString::from(format!("tweak-{}", t.id)))
            .flex()
            .items_center()
            .gap(px(12.0))
            .px(px(12.0))
            .py(px(9.0))
            .rounded(px(8.0))
            .cursor_pointer()
            .bg(theme::white(if on { 0.1 } else { 0.03 }))
            .hover(|s| s.bg(theme::white(if on { 0.1 } else { 0.06 })))
            .border_1()
            .border_color(if on { theme::accent().opacity(0.7) } else { theme::white(0.08) })
            .child(
                div()
                    .w(px(28.0))
                    .flex()
                    .justify_center()
                    .font_family("Segoe UI Symbol")
                    .text_size(px(18.0))
                    .text_color(tint)
                    .child(symbol(t.id)),
            )
            .child(
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(div().font_weight(FontWeight::MEDIUM).child(t.title))
                    .child(div().text_size(px(11.0)).text_color(theme::secondary()).child(t.detail)),
            )
            .child(mark)
            .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| {
                let Some(base) = this.guide.as_ref().map(|g| g.base.clone()) else { return };
                this.edit(cx, |c| t.toggle(c, &base));
            }))
            .into_any_element()
    }

    fn guide_finish(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let Some(g) = &self.guide else { return div().into_any_element() };
        let title = self.store.config.scene.title();
        let lock = g.lock_screen_choice.unwrap_or(self.store.config.lock_screen_still);
        let text = if g.on_desktop {
            format!("{title} is on every display. You can change anything later from the tray icon, under Customize.")
        } else {
            format!("Set as Wallpaper puts {title} on every display. You can change anything later from the tray icon, under Customize.")
        };
        div()
            .flex()
            .flex_col()
            .gap(px(14.0))
            .child(heading("Ready when you are"))
            .child(text)
            .child(Checkbox::new("guide-login").label("Start Deep Field when you sign in").checked(g.launch_at_login).on_click(
                cx.listener(|this: &mut Settings, on: &bool, _, cx| {
                    if let Some(g) = &mut this.guide {
                        g.launch_at_login = *on;
                    }
                    cx.notify();
                }),
            ))
            .child(Checkbox::new("guide-lock").label("Show a still of this scene on the lock screen").checked(lock).on_click(
                cx.listener(|this: &mut Settings, on: &bool, _, cx| {
                    if let Some(g) = &mut this.guide {
                        g.lock_screen_choice = Some(*on);
                    }
                    cx.notify();
                }),
            ))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(theme::secondary())
                    .child("The lock screen can't animate, so it shows a still. Your own picture comes back if you turn this off."),
            )
            .into_any_element()
    }

    fn guide_navigation(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let Some(g) = &self.guide else { return div().into_any_element() };
        let (step, on_desktop) = (g.step, g.on_desktop);
        let last = step == STEPS - 1;
        let left = if last && !on_desktop {
            Some(
                Button::new("guide-not-now")
                    .label("Not Now")
                    .tooltip("Close the guide without changing your desktop. Turn it on later from the tray icon.")
                    .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, window, cx| this.guide_done(false, window, cx))),
            )
        } else if step > 0 {
            Some(
                Button::new("guide-back")
                    .label("Back")
                    .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, _, cx| this.guide_move(-1, cx))),
            )
        } else {
            None
        };
        let right = if last {
            Button::new("guide-done")
                .label(if on_desktop { "Done" } else { "Set as Wallpaper" })
                .primary()
                .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, window, cx| this.guide_done(true, window, cx)))
        } else {
            Button::new("guide-next")
                .label(if step == 0 { "Get Started" } else { "Continue" })
                .primary()
                .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, _, cx| this.guide_move(1, cx)))
        };
        div()
            .pt(px(16.0))
            .pb(px(PAD))
            // Opaque and down to the window's edge: a gallery row scrolled wholly out of view can
            // still leak a line of pixels below its clip, which this covers.
            .bg(theme::inspector_bg())
            .flex()
            .items_center()
            .justify_between()
            .child(div().when_some(left, |d, b| d.child(b)))
            .child(right)
            .into_any_element()
    }
}

fn heading(text: &'static str) -> Div {
    div().text_size(px(20.0)).font_weight(FontWeight::SEMIBOLD).child(text)
}

/// One dot per step, the current one drawn long.
fn step_dots(step: usize) -> Div {
    div().flex().gap(px(6.0)).children((0..STEPS).map(|s| {
        div()
            .h(px(6.0))
            .w(px(if s == step { 18.0 } else { 6.0 }))
            .rounded_full()
            .bg(if s == step { theme::accent() } else { theme::white(0.2) })
    }))
}
