//! The window: the stage (preview, caption and scene gallery) on the left and the inspector (a
//! section picker and that section's controls) on the right, as in CustomizeView.swift.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use deepfield::config::{SceneKind, WallpaperConfig};
use deepfield::config_store::ConfigStore;
use gpui_kit::component::color_picker::ColorPickerState;
use gpui_kit::component::slider::SliderState;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;

use crate::render::{self, Frame, Job, Output};
use crate::system;
use crate::theme;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Section {
    Scene,
    Sky,
    Image,
    System,
}

impl Section {
    pub const ALL: [Section; 4] = [Section::Scene, Section::Sky, Section::Image, Section::System];
    pub fn title(self) -> &'static str {
        match self {
            Section::Scene => "Scene",
            Section::Sky => "Sky",
            Section::Image => "Image",
            Section::System => "System",
        }
    }
}

gpui_kit::actions!(deepfield, [ShowScene, ShowSky, ShowImage, ShowSystem, PreviousScene, NextScene, CloseWindow]);

/// The window's keys, as on the Mac with Ctrl for Cmd: Ctrl+1 to Ctrl+4 pick a section, Ctrl+[
/// and Ctrl+] step through the scenes, Ctrl+W closes.
pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("ctrl-1", ShowScene, None),
        KeyBinding::new("ctrl-2", ShowSky, None),
        KeyBinding::new("ctrl-3", ShowImage, None),
        KeyBinding::new("ctrl-4", ShowSystem, None),
        KeyBinding::new("ctrl-[", PreviousScene, None),
        KeyBinding::new("ctrl-]", NextScene, None),
        KeyBinding::new("ctrl-w", CloseWindow, None),
    ]);
}

/// Writes at most this often while a slider moves; the wallpaper re-reads the file on change.
const SAVE_INTERVAL: Duration = Duration::from_millis(100);
/// Thumbnails re-render once a change settles, not on every step of a drag.
const THUMB_DELAY: Duration = Duration::from_millis(300);

pub struct Settings {
    pub store: ConfigStore,
    /// the saved presets, shared with the tray menu through presets.json
    pub presets: deepfield::presets::PresetStore,
    pub section: Section,
    dirty: bool,
    last_save: Instant,
    last_reload_check: Instant,

    jobs: Sender<Job>,
    outputs: Receiver<Output>,
    preview: Option<Arc<RenderImage>>,
    preview_error: Option<String>,
    /// what the last preview request was for, so a change sends a new one
    preview_sent: Option<(WallpaperConfig, (u32, u32), bool)>,
    pub actual_pixels: bool,
    paused: bool,
    retired: Vec<Arc<RenderImage>>,

    thumbs: HashMap<SceneKind, Arc<RenderImage>>,
    thumb_sent: HashMap<SceneKind, (WallpaperConfig, (u32, u32), u64)>,
    thumb_generation: u64,
    thumbs_due: Option<Instant>,

    pub screen: (u32, u32),
    hwnd: Option<isize>,

    pub sliders: HashMap<&'static str, Entity<SliderState>>,
    pub colors: HashMap<&'static str, Entity<ColorPickerState>>,
    pub subscriptions: Vec<Subscription>,

    pub planets_collapsed: bool,
    pub camera_collapsed: bool,
    pub login_item: bool,
    /// each display's refresh rate, for the frame rates offered
    pub display_rates: Vec<i64>,
    pub confirm_reset_until: Option<Instant>,
    status: Option<(String, Instant)>,
    focus: FocusHandle,
}

impl Settings {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Settings {
        let (out_tx, out_rx) = mpsc::channel();
        let jobs = render::spawn(out_tx);
        // a steady tick: picks up rendered frames, saves pending changes, notices outside edits
        cx.spawn_in(window, async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_millis(15)).await;
            if this.update_in(cx, |this, window, cx| this.tick(window, cx)).is_err() {
                break;
            }
        })
        .detach();
        cx.on_release(|this: &mut Settings, _| this.flush()).detach();
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Settings {
            focus,
            store: ConfigStore::load(),
            presets: deepfield::presets::PresetStore::load(),
            section: Section::Scene,
            dirty: false,
            last_save: Instant::now(),
            last_reload_check: Instant::now(),
            jobs,
            outputs: out_rx,
            preview: None,
            preview_error: None,
            preview_sent: None,
            actual_pixels: false,
            paused: false,
            retired: Vec::new(),
            thumbs: HashMap::new(),
            thumb_sent: HashMap::new(),
            thumb_generation: 0,
            thumbs_due: Some(Instant::now()),
            screen: system::screen_size(),
            hwnd: None,
            sliders: HashMap::new(),
            colors: HashMap::new(),
            subscriptions: Vec::new(),
            planets_collapsed: false,
            camera_collapsed: false,
            login_item: system::login_item().is_some(),
            display_rates: deepfield::wallpaper::display_rates(),
            confirm_reset_until: None,
            status: None,
        }
    }

    pub fn config(&self) -> &WallpaperConfig {
        &self.store.config
    }

    /// Every change goes through here: the config changes, the file follows (throttled), the
    /// preview and thumbnails catch up.
    pub fn edit(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut WallpaperConfig)) {
        let before = self.store.config.clone();
        f(&mut self.store.config);
        if self.store.config == before {
            return;
        }
        self.dirty = true;
        if self.last_save.elapsed() >= SAVE_INTERVAL {
            self.flush();
        }
        self.thumbs_due = Some(Instant::now() + THUMB_DELAY);
        cx.notify();
    }

    /// Writes the config beside the real file and renames it into place, so the wallpaper (which
    /// re-reads on every change of the file's time) never reads a half-written file.
    pub fn flush(&mut self) {
        if !self.dirty {
            return;
        }
        self.dirty = false;
        self.last_save = Instant::now();
        let path = self.store.path().clone();
        let tmp = path.with_extension("json.saving");
        let written = serde_json::to_string_pretty(&self.store.config)
            .map_err(|e| e.to_string())
            .and_then(|text| {
                if let Some(dir) = path.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                std::fs::write(&tmp, text).map_err(|e| e.to_string())
            })
            .and_then(|_| std::fs::rename(&tmp, &path).map_err(|e| e.to_string()));
        match written {
            // take in the file's new time, so our own write doesn't read as an outside change
            Ok(()) => {
                self.store.reload_if_changed();
            }
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                self.flash(format!("Couldn't save the settings: {e}"));
            }
        }
    }

    pub fn select_scene(&mut self, kind: SceneKind, cx: &mut Context<Self>) {
        self.edit(cx, |c| c.set_scene(kind));
    }

    fn step_scene(&mut self, step: isize, cx: &mut Context<Self>) {
        let scenes = Self::scenes();
        let Some(i) = scenes.iter().position(|k| *k == self.store.config.scene) else { return };
        let n = scenes.len() as isize;
        self.select_scene(scenes[((i as isize + step + n) % n) as usize], cx);
    }

    fn show(&mut self, section: Section, cx: &mut Context<Self>) {
        self.section = section;
        cx.notify();
    }

    pub fn flash(&mut self, text: impl Into<String>) {
        self.status = Some((text.into(), Instant::now()));
    }

    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let mut changed = false;

        for image in self.retired.drain(..) {
            let _ = window.drop_image(image);
        }
        while let Ok(out) = self.outputs.try_recv() {
            match out {
                Output::Preview(frame) => {
                    if let Some(old) = self.preview.replace(to_image(frame)) {
                        self.retired.push(old);
                    }
                    changed = true;
                }
                Output::Thumbnail { kind, frame, generation } => {
                    // only the newest request for each scene counts
                    if self.thumb_sent.get(&kind).is_some_and(|s| s.2 == generation) {
                        if let Some(old) = self.thumbs.insert(kind, to_image(frame)) {
                            self.retired.push(old);
                        }
                        changed = true;
                    }
                }
                Output::Failed(e) => {
                    self.preview_error = Some(e);
                    changed = true;
                }
            }
        }

        if self.dirty && self.last_save.elapsed() >= SAVE_INTERVAL {
            self.flush();
        }

        // the tray menu or a text editor may change the file underneath
        if !self.dirty && self.last_reload_check.elapsed() >= Duration::from_millis(500) {
            self.last_reload_check = Instant::now();
            if self.store.reload_if_changed() {
                self.thumbs_due = Some(Instant::now());
                self.flash("Settings changed outside this window");
                changed = true;
            }
            // presets applied from the tray menu
            if self.presets.reload_if_changed() {
                changed = true;
            }
            // the tray's Save, Import and Export, which need this window's dialogs
            let request = deepfield::tray::customize_request_path();
            if let Ok(r) = std::fs::read_to_string(&request) {
                let _ = std::fs::remove_file(&request);
                match r.trim() {
                    "save-preset" => self.prompt_save_preset(window, cx),
                    "import-preset" => self.prompt_import_presets(cx),
                    "export-preset" => self.prompt_export_preset(None, window, cx),
                    _ => {}
                }
                changed = true;
            }
        }

        // pause the preview while the window is minimized
        if self.hwnd.is_none() {
            self.hwnd = system::window().map(|h| h.0 as isize);
        }
        let minimized = self.hwnd.is_some_and(|h| system::is_minimized(windows::Win32::Foundation::HWND(h as *mut _)));
        if minimized != self.paused {
            self.paused = minimized;
            let _ = self.jobs.send(Job::Pause(minimized));
        }

        // a new preview request whenever the look or the preview's size changes
        let shown = self.preview_device_size(window);
        let want = (self.store.config.clone(), shown, self.actual_pixels);
        if self.preview_sent.as_ref() != Some(&want) {
            let _ = self.jobs.send(Job::Preview {
                config: self.store.config.clone(),
                screen: self.screen,
                shown,
                actual: self.actual_pixels,
            });
            self.preview_sent = Some(want);
        }

        if self.thumbs_due.is_some_and(|t| Instant::now() >= t) {
            self.thumbs_due = None;
            self.request_thumbnails(window);
        }

        if self.status.as_ref().is_some_and(|(_, t)| t.elapsed() > Duration::from_secs(4)) {
            self.status = None;
            changed = true;
        }
        if self.confirm_reset_until.is_some_and(|t| Instant::now() > t) {
            self.confirm_reset_until = None;
            changed = true;
        }
        if changed {
            cx.notify();
        }
    }

    // MARK: layout (Theme.swift)

    fn stage_size(&self, window: &Window) -> (f32, f32) {
        let v = window.viewport_size();
        let w = f32::from(v.width) - theme::INSPECTOR_W - 1.0 - 2.0 * theme::STAGE_PAD_X;
        let h = f32::from(v.height) - 2.0 * theme::STAGE_PAD_Y;
        (w.max(theme::PREVIEW_BOX.0), h.max(200.0))
    }

    /// `size` scaled to fit inside `bx`, keeping its aspect ratio.
    pub fn fit(size: (f32, f32), bx: (f32, f32)) -> (f32, f32) {
        let aspect = size.0 / size.1.max(1.0);
        if aspect >= bx.0 / bx.1 {
            (bx.0, bx.0 / aspect)
        } else {
            (bx.1 * aspect, bx.1)
        }
    }

    fn screen_f(&self) -> (f32, f32) {
        (self.screen.0 as f32, self.screen.1 as f32)
    }

    /// The box a gallery thumbnail fits in, and the column count. A wide screen gives a short
    /// preview, so the gallery takes the leftover height as four larger columns.
    pub fn gallery_box(&self) -> ((f32, f32), usize) {
        if Self::fit(self.screen_f(), theme::PREVIEW_BOX).1 < 340.0 {
            ((162.0, 102.0), 4)
        } else {
            ((128.0, 80.0), 5)
        }
    }

    pub fn thumb_size(&self) -> (f32, f32) {
        let s = Self::fit(self.screen_f(), self.gallery_box().0);
        (s.0.round().max(16.0), s.1.round().max(16.0))
    }

    /// The preview grows with the window: the stage's full width, and as tall as leaves the
    /// caption and one row of the gallery in view.
    pub fn preview_box(&self, window: &Window) -> (f32, f32) {
        let stage = self.stage_size(window);
        let row = self.gallery_box().0 .1 + 40.0;
        let h = (stage.1 - theme::CAPTION_H - 12.0 - row).max(theme::PREVIEW_BOX.1 * 0.6);
        (stage.0, h)
    }

    pub fn preview_fitted(&self, window: &Window) -> (f32, f32) {
        let f = Self::fit(self.screen_f(), self.preview_box(window));
        (f.0.floor(), f.1.floor())
    }

    fn preview_device_size(&self, window: &Window) -> (u32, u32) {
        let f = self.preview_fitted(window);
        let s = window.scale_factor();
        ((f.0 * s).round() as u32, (f.1 * s).round() as u32)
    }

    pub fn gallery_columns(&self, window: &Window) -> usize {
        let ((bw, _), base) = self.gallery_box();
        let width = self.stage_size(window).0;
        base.max(((width + 10.0) / (bw + 10.0)) as usize)
    }

    pub fn scenes() -> Vec<SceneKind> {
        SceneKind::listed().into_iter().filter(|s| s.is_ported()).collect()
    }

    /// The settings a still of `kind` depends on, as SceneThumbnails.swift sets them: one shaded
    /// pixel per point, so shown 1:1 it has the wallpaper's dither look.
    fn thumb_config(&self, kind: SceneKind) -> WallpaperConfig {
        let mut c = self.store.config.clone();
        c.set_scene(kind);
        c.phone_framing = None;
        c.pixel_size = 1;
        c.fps = 24;
        c.lock_screen_still = false;
        c.lock_screen_smooth = false;
        c
    }

    fn request_thumbnails(&mut self, window: &Window) {
        let (w, h) = self.thumb_size();
        let s = window.scale_factor();
        let shown = ((w * s).round() as u32, (h * s).round() as u32);
        let cells = (w as u32, h as u32);
        self.thumb_generation += 1;
        // the selected scene first, so the one being edited catches up soonest
        let mut order = Self::scenes();
        if let Some(i) = order.iter().position(|k| *k == self.store.config.scene) {
            let k = order.remove(i);
            order.insert(0, k);
        }
        for kind in order {
            let c = self.thumb_config(kind);
            if self.thumb_sent.get(&kind).is_some_and(|s| s.0 == c && s.1 == shown) {
                continue;
            }
            self.thumb_sent.insert(kind, (c.clone(), shown, self.thumb_generation));
            let _ = self.jobs.send(Job::Thumbnail { kind, config: c, cells, shown, generation: self.thumb_generation });
        }
    }

    // MARK: rendering

    fn render_stage(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let bx = self.preview_box(window);
        let fitted = self.preview_fitted(window);
        let preview = div()
            .w(px(fitted.0))
            .h(px(fitted.1))
            .bg(gpui_kit::black())
            .border_1()
            .border_color(theme::white(0.14))
            .overflow_hidden()
            .flex()
            .items_center()
            .justify_center()
            .when_some(self.preview.clone(), |d, image| d.child(img(image).w(px(fitted.0 - 2.0)).h(px(fitted.1 - 2.0))))
            .when_some(self.preview_error.clone(), |d, e| {
                d.child(div().p_4().text_color(theme::secondary()).child(format!("The preview couldn't start: {e}")))
            });

        let caption_text = match &self.status {
            Some((m, _)) => div().text_color(theme::text()).child(m.clone()),
            None => div().text_color(theme::secondary()).child(format!("{} \u{d7} {}", self.screen.0, self.screen.1)),
        };
        let scale_picker = crate::controls::segmented(
            "preview-scale",
            vec![("Fit".into(), !self.actual_pixels), ("1:1".into(), self.actual_pixels)],
            true,
            cx.listener(|this: &mut Settings, i: &usize, _, cx| {
                this.actual_pixels = *i == 1;
                cx.notify();
            }),
        );
        let caption = div()
            .w(px(bx.0))
            .h(px(theme::CAPTION_H))
            .flex()
            .items_center()
            .justify_between()
            .text_size(px(11.0))
            .child(caption_text.overflow_hidden().whitespace_nowrap().text_ellipsis())
            .child(div().w(px(96.0)).child(scale_picker));

        let columns = self.gallery_columns(window);
        let gallery = self.render_gallery(columns, cx);

        div()
            .flex_1()
            .h_full()
            .min_w(px(0.0))
            .bg(theme::stage_bg())
            .px(px(theme::STAGE_PAD_X))
            .py(px(theme::STAGE_PAD_Y))
            .flex()
            .flex_col()
            .child(div().w(px(bx.0)).flex().justify_center().child(preview))
            .child(caption)
            .child(
                div()
                    .id("gallery")
                    .flex_1()
                    .min_h(px(0.0))
                    .mt(px(12.0))
                    .overflow_y_scroll()
                    .child(gallery),
            )
    }

    fn render_gallery(&mut self, columns: usize, cx: &mut Context<Self>) -> impl IntoElement {
        let (w, h) = self.thumb_size();
        let selected = self.store.config.scene;
        let cells = Self::scenes().into_iter().map(|kind| {
            let is_sel = kind == selected;
            let image = self.thumbs.get(&kind).cloned();
            div()
                .id(SharedString::from(format!("scene-{}", kind.raw())))
                .w(px(w))
                .flex()
                .flex_col()
                .gap(px(4.0))
                .cursor_pointer()
                .child(
                    div()
                        .w(px(w))
                        .h(px(h))
                        .bg(gpui_kit::black())
                        .overflow_hidden()
                        .when_some(image, |d, i| d.child(img(i).w(px(w)).h(px(h))))
                        .when(is_sel, |d| d.border_2().border_color(theme::accent()))
                        .when(!is_sel, |d| {
                            d.border_1().border_color(theme::white(0.14)).group_hover("thumb", |s| s.border_color(theme::white(0.4)))
                        }),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .whitespace_nowrap()
                        .overflow_hidden()
                        .text_ellipsis()
                        .text_color(if is_sel { theme::text() } else { theme::secondary() })
                        .when(is_sel, |d| d.font_weight(FontWeight::MEDIUM))
                        .child(kind.title()),
                )
                .group("thumb")
                .tooltip(move |window, cx| gpui_kit::component::tooltip::Tooltip::new(crate::model::blurb(kind)).build(window, cx))
                .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| this.select_scene(kind, cx)))
        });
        let cells: Vec<_> = cells.collect();
        let mut rows = Vec::new();
        let mut it = cells.into_iter().peekable();
        while it.peek().is_some() {
            let row: Vec<_> = it.by_ref().take(columns).collect();
            rows.push(div().flex().gap(px(10.0)).children(row));
        }
        div().flex().flex_col().gap(px(10.0)).py(px(2.0)).children(rows)
    }

    fn render_inspector(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let current = self.section;
        let picker = crate::controls::segmented(
            "section",
            Section::ALL.iter().map(|s| (SharedString::from(s.title()), *s == current)).collect(),
            false,
            cx.listener(|this: &mut Settings, i: &usize, _, cx| {
                this.section = Section::ALL[*i];
                cx.notify();
            }),
        );
        let body = match self.section {
            Section::Scene => crate::tabs::scene_tab(self, window, cx),
            Section::Sky => crate::tabs::sky_tab(self, window, cx),
            Section::Image => crate::tabs::image_tab(self, window, cx),
            Section::System => crate::tabs::system_tab(self, window, cx),
        };
        div()
            .w(px(theme::INSPECTOR_W))
            .flex_none()
            .h_full()
            .bg(theme::inspector_bg())
            .border_l_1()
            .border_color(theme::white(0.08))
            .flex()
            .flex_col()
            .child(div().px(px(20.0)).pt(px(12.0)).child(picker))
            .child(div().px(px(14.0)).pt(px(4.0)).pb(px(4.0)).flex().justify_end().child(self.render_presets_menu(cx)))
            .child(
                div()
                    .id(SharedString::from(format!("inspector-{:?}", self.section)))
                    .flex_1()
                    .min_h(px(0.0))
                    .overflow_y_scroll()
                    .child(div().px(px(20.0)).pt(px(6.0)).pb(px(24.0)).flex().flex_col().gap(px(18.0)).children(body)),
            )
    }
}

impl Render for Settings {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let stage = self.render_stage(window, cx);
        let inspector = self.render_inspector(window, cx);
        div()
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &ShowScene, _, cx| this.show(Section::Scene, cx)))
            .on_action(cx.listener(|this, _: &ShowSky, _, cx| this.show(Section::Sky, cx)))
            .on_action(cx.listener(|this, _: &ShowImage, _, cx| this.show(Section::Image, cx)))
            .on_action(cx.listener(|this, _: &ShowSystem, _, cx| this.show(Section::System, cx)))
            .on_action(cx.listener(|this, _: &PreviousScene, _, cx| this.step_scene(-1, cx)))
            .on_action(cx.listener(|this, _: &NextScene, _, cx| this.step_scene(1, cx)))
            .on_action(cx.listener(|this, _: &CloseWindow, window, _| {
                this.flush();
                window.remove_window();
            }))
            .size_full()
            .flex()
            .flex_row()
            .font_family("Segoe UI")
            .text_size(px(13.0))
            .text_color(theme::text())
            .bg(theme::stage_bg())
            .child(stage)
            .child(inspector)
    }
}

/// A rendered frame as a GPUI image (which keeps BGRA).
fn to_image(frame: Frame) -> Arc<RenderImage> {
    let mut rgba = frame.rgba;
    for px in rgba.chunks_exact_mut(4) {
        px.swap(0, 2);
    }
    let buffer = image::RgbaImage::from_raw(frame.width, frame.height, rgba).expect("frame size");
    Arc::new(RenderImage::new(vec![image::Frame::new(buffer)]))
}
