//! Deep Field's Customize window for Windows, after the macOS app's (Sources/DeepField/UI).
//! It edits %APPDATA%\DeepField\config.json, which the running wallpaper re-reads within a
//! second, and previews the look with the deepfield library's renderer.
#![windows_subsystem = "windows"]

mod app;
mod controls;
mod model;
mod presets_menu;
mod render;
mod schedule_tab;
mod system;
mod tabs;
mod theme;
mod welcome;

use std::sync::Arc;

use gpui_kit::*;

fn main() {
    if !system::claim_single_instance() {
        return;
    }
    // Opened for the welcome guide (the wallpaper's first launch, or the tray's Welcome Guide
    // while this wasn't running): the window starts at the guide's size, as the guide.
    let request = deepfield::tray::customize_request_path();
    let welcome = std::env::args().any(|a| a == "--welcome")
        || std::fs::read_to_string(&request).is_ok_and(|r| r.trim() == "welcome");
    if welcome {
        let _ = std::fs::remove_file(&request);
    }
    gpui_kit::application().with_assets(gpui_kit::assets::Assets).run(move |cx| {
        gpui_kit::init(cx);
        theme::apply(cx);
        app::bind_keys(cx);
        let (w, h, title) = if welcome {
            (welcome::WINDOW.0, welcome::WINDOW.1, system::WELCOME_TITLE)
        } else {
            (theme::WINDOW_W, theme::WINDOW_H, system::WINDOW_TITLE)
        };
        let size = size(px(w), px(h));
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(None, size, cx))),
            titlebar: Some(TitlebarOptions { title: Some(title.into()), ..Default::default() }),
            window_min_size: Some(gpui_kit::size(px(theme::MIN_W), px(theme::MIN_H))),
            icon: Some(Arc::new(theme::icon())),
            app_id: Some("DeepField.Settings".into()),
            ..Default::default()
        };
        let opened = gpui_kit::open_window(options, cx, |window, cx| cx.new(|cx| {
            let mut s = app::Settings::new(window, cx);
            if welcome {
                s.open_guide(true, window, cx);
            }
            s
        }));
        if let Err(e) = opened {
            deepfield::error_box(&format!("Could not open the settings window: {e}"));
            cx.quit();
            return;
        }
        system::dark_title_bar();
        // closing the window ends the app; the view saves any pending change as it goes
        cx.on_window_closed(|cx, _| cx.quit()).detach();
        cx.activate(true);
    });
}
