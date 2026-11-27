//! Deep Field's Customize window for Windows, after the macOS app's (Sources/DeepField/UI).
//! It edits %APPDATA%\DeepField\config.json, which the running wallpaper re-reads within a
//! second, and previews the look with the deepfield library's renderer.
#![windows_subsystem = "windows"]

mod app;
mod controls;
mod model;
mod presets_menu;
mod render;
mod system;
mod tabs;
mod theme;

use std::sync::Arc;

use gpui_kit::*;

fn main() {
    if !system::claim_single_instance() {
        return;
    }
    gpui_kit::application().with_assets(gpui_kit::assets::Assets).run(|cx| {
        gpui_kit::init(cx);
        theme::apply(cx);
        app::bind_keys(cx);
        let size = size(px(theme::WINDOW_W), px(theme::WINDOW_H));
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(None, size, cx))),
            titlebar: Some(TitlebarOptions { title: Some(system::WINDOW_TITLE.into()), ..Default::default() }),
            window_min_size: Some(gpui_kit::size(px(theme::MIN_W), px(theme::MIN_H))),
            icon: Some(Arc::new(theme::icon())),
            app_id: Some("DeepField.Settings".into()),
            ..Default::default()
        };
        let opened = gpui_kit::open_window(options, cx, |window, cx| cx.new(|cx| app::Settings::new(window, cx)));
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
