//! The Phone section (UI/PhoneTab.swift and Mobile/PhoneExporter.swift): a portrait
//! recomposition of the current scene as a phone wallpaper, previewed on the stage in place of
//! the landscape preview. The still saves as a PNG and the loop as an MP4; the Mac's Live Photo
//! (and Add to Photos) needs Apple's frameworks, so the loop stands in for its movie.

use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use deepfield::mobile_export::{self, MobileOptions, Plan, PHONES, PIXEL_SIZES};
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;

use crate::app::Settings;
use crate::controls::{row, segmented, Group, ValueSlider};
use crate::render::Job;
use crate::theme;

/// The largest the phone preview gets on the stage, as on the Mac.
const BOX: (f32, f32) = (394.0, 676.0);
const CAPTION_H: f32 = 30.0;
pub const GALLERY_SPACING: f32 = 20.0;

pub struct PhoneState {
    pub options: MobileOptions,
    /// an entry of `PHONES`, or None for a custom size
    pub model: Option<usize>,
    pub show_clock: bool,
    pub preview: Option<Arc<RenderImage>>,
    /// what the last preview request was for, so a change sends a new one
    pub sent: Option<(Plan, (u32, u32))>,
    pub generation: u64,
    pub busy: bool,
    pub progress: Option<f64>,
    pub status: String,
    /// the custom size's width and height fields, made when first shown
    size_inputs: Option<(Entity<InputState>, Entity<InputState>)>,
}

impl Default for PhoneState {
    fn default() -> PhoneState {
        PhoneState {
            options: MobileOptions::default(),
            model: Some(0),
            show_clock: true,
            preview: None,
            sent: None,
            generation: 0,
            busy: false,
            progress: None,
            status: String::new(),
            size_inputs: None,
        }
    }
}

impl Settings {
    pub fn phone_plan(&self) -> Plan {
        mobile_export::plan(self.config(), &self.phone.options)
    }

    /// The preview's size on a stage `stage_h` tall, fitted to the export's shape: it shrinks to
    /// fit short windows, and is capped so the gallery keeps its room in tall ones.
    pub fn phone_fitted(&self, stage_h: f32) -> (f32, f32) {
        let o = &self.phone.options;
        let size = (mobile_export::clamped_side(o.width) as f32, mobile_export::clamped_side(o.height) as f32);
        let box_h = BOX.1.min((stage_h - CAPTION_H).max(1.0));
        let f = Settings::fit(size, (BOX.0, box_h));
        (f.0.floor(), f.1.floor())
    }

    /// Sends a new preview request when the plan or the preview's size changed.
    pub fn request_phone_preview(&mut self, shown: (u32, u32)) {
        let plan = self.phone_plan();
        let want = (plan.clone(), shown);
        if self.phone.sent.as_ref() == Some(&want) {
            return;
        }
        self.phone.generation += 1;
        let _ = self.jobs.send(Job::Phone { plan, shown, generation: self.phone.generation });
        self.phone.sent = Some(want);
    }

    fn phone_edit(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut MobileOptions)) {
        f(&mut self.phone.options);
        cx.notify();
    }

    // MARK: stage

    /// The phone preview and its caption (PhoneStage), with the gallery beside it.
    pub fn render_phone_stage(&mut self, stage: (f32, f32), cx: &mut Context<Self>) -> AnyElement {
        let fitted = self.phone_fitted(stage.1);
        let (w, h) = fitted;
        let o = self.phone.options;
        let radius = w * 0.12;
        let mut screen = div()
            .relative()
            .w(px(w))
            .h(px(h))
            .bg(gpui_kit::black())
            .rounded(px(radius))
            .border_1()
            .border_color(theme::white(0.3))
            .overflow_hidden()
            .when_some(self.phone.preview.clone(), |d, image| d.child(img(image).size_full()));
        if self.phone.show_clock {
            screen = screen.child(clock_guide(fitted));
        }
        let caption = format!(
            "{} \u{d7} {}{}",
            mobile_export::clamped_side(o.width),
            mobile_export::clamped_side(o.height),
            if o.smooth { ", smooth" } else { "" }
        );
        let column = div()
            .flex_none()
            .flex()
            .flex_col()
            .child(screen)
            .child(
                div()
                    .h(px(CAPTION_H))
                    .flex()
                    .items_center()
                    .text_size(px(11.0))
                    .text_color(theme::secondary())
                    .whitespace_nowrap()
                    .child(caption),
            );
        // two thumbnail columns beside the preview, or one where two don't fit
        let thumb_w = self.thumb_size().0;
        let room = stage.0 - w - GALLERY_SPACING;
        let columns = if room >= thumb_w * 2.0 + 10.0 { 2 } else { 1 };
        let gallery = self.render_gallery(columns, cx);
        div()
            .flex()
            .gap(px(GALLERY_SPACING))
            .size_full()
            .child(column)
            .child(div().id("phone-gallery").flex_1().min_w(px(0.0)).h_full().overflow_y_scroll().child(gallery))
            .into_any_element()
    }

    // MARK: inspector

    pub fn phone_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        vec![
            self.phone_device_group(window, cx).into_element(),
            self.phone_look_group(window, cx).into_element(),
            self.phone_export_group(cx).into_element(),
        ]
    }

    fn phone_device_group(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Group {
        let o = self.phone.options;
        let model = self.phone.model;
        let current = model.map_or("Custom size".to_string(), |i| PHONES[i].name.to_string());
        let mut options: Vec<(String, bool)> =
            PHONES.iter().enumerate().map(|(i, p)| (p.name.to_string(), model == Some(i))).collect();
        options.push(("Custom size".into(), model.is_none()));
        let menu = self.phone_menu("phone-model", current, options, |this, i, window, cx| {
            if i < PHONES.len() {
                this.phone.model = Some(i);
                this.phone.options.width = PHONES[i].width;
                this.phone.options.height = PHONES[i].height;
            } else {
                this.phone.model = None;
                // the fields start from the size shown, not from an earlier custom size
                this.phone.size_inputs = None;
                this.ensure_size_inputs(window, cx);
            }
        }, cx);
        let mut rows = vec![row("Model", None, menu)];
        if model.is_none() {
            self.ensure_size_inputs(window, cx);
            let (wi, hi) = self.phone.size_inputs.clone().expect("size inputs");
            rows.push(row(
                "Size in pixels",
                None,
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .child(div().w(px(72.0)).child(Input::new(&wi).small()))
                    .child("\u{d7}")
                    .child(div().w(px(72.0)).child(Input::new(&hi).small())),
            ));
        } else {
            rows.push(row(
                "Size in pixels",
                None,
                div().text_color(theme::secondary()).child(format!("{} \u{d7} {}", o.width, o.height)),
            ));
        }
        Group::titled("iPhone").rows(rows)
    }

    /// The custom size's fields. The size follows the typing, always in range; the text stays as
    /// typed, since clamping it sooner would break up "1320" at "1".
    fn ensure_size_inputs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.phone.size_inputs.is_some() {
            return;
        }
        let o = self.phone.options;
        let make = |value: u32, window: &mut Window, cx: &mut Context<Self>| {
            cx.new(|cx| InputState::new(window, cx).default_value(value.to_string()))
        };
        let wi = make(o.width, window, cx);
        let hi = make(o.height, window, cx);
        for (input, is_width) in [(wi.clone(), true), (hi.clone(), false)] {
            self.subscriptions.push(cx.subscribe(&input, move |this: &mut Settings, state, ev: &InputEvent, cx| {
                if let InputEvent::Change = ev {
                    let text = state.read(cx).value();
                    if let Ok(v) = text.trim().parse::<u32>() {
                        let v = mobile_export::clamped_side(v);
                        this.phone_edit(cx, |o| if is_width { o.width = v } else { o.height = v });
                    }
                }
            }));
        }
        self.phone.size_inputs = Some((wi, hi));
    }

    fn phone_look_group(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Group {
        let o = self.phone.options;
        let desktop = self.config().pixel_size;
        let style = segmented(
            "phone-style",
            vec![("Dithered".into(), !o.smooth), ("Smooth".into(), o.smooth)],
            false,
            cx.listener(|this: &mut Settings, i: &usize, _, cx| {
                let smooth = *i == 1;
                this.phone_edit(cx, |o| o.smooth = smooth);
            }),
        );
        let mut rows = vec![div().py(px(8.0)).flex().flex_col().gap(px(6.0)).child("Style").child(style).into_any_element()];
        if !o.smooth {
            let auto = format!("Auto ({} px)", MobileOptions::auto_pixel_size(desktop));
            let current = if o.pixel_size == 0 { auto.clone() } else { format!("{} px", o.pixel_size) };
            let mut options = vec![(auto, o.pixel_size == 0)];
            options.extend(PIXEL_SIZES.iter().map(|n| (format!("{n} px"), o.pixel_size == *n)));
            let menu = self.phone_menu("phone-pixel", current, options, |this, i, _, _| {
                this.phone.options.pixel_size = if i == 0 { 0 } else { PIXEL_SIZES[i - 1] };
            }, cx);
            rows.push(row("Pixel size", None, menu));
        }
        let zoom = ValueSlider {
            key: "phone-zoom", title: "Zoom", lo: 0.6, hi: 1.8, fmt: |v| format!("{v:.2}\u{d7}"), help: None,
        };
        rows.push(self.value_slider_row(zoom, o.framing.zoom, Rc::new(|this: &mut Settings, v, cx| {
            this.phone_edit(cx, |o| o.framing.zoom = v);
        }), window, cx));
        // it moves the camera's aim, which a scene that draws the real sky doesn't use
        if !self.config().scene.draws_real_sky() {
            let shift = ValueSlider {
                key: "phone-shift", title: "Subject height", lo: -0.25, hi: 0.25,
                fmt: |v| format!("{:+.0}%", v * 100.0), help: None,
            };
            rows.push(self.value_slider_row(shift, o.framing.shift, Rc::new(|this: &mut Settings, v, cx| {
                this.phone_edit(cx, |o| o.framing.shift = v);
            }), window, cx));
        }
        let clock = Switch::new("phone-clock").checked(self.phone.show_clock).color(theme::accent()).on_click(
            cx.listener(|this: &mut Settings, on: &bool, _, cx| {
                this.phone.show_clock = *on;
                cx.notify();
            }),
        );
        let reset = o.framing.reset(self.config().scene);
        let reset_button = Button::new("phone-reset-framing")
            .label("Reset Framing")
            .small()
            .disabled(o.framing == reset)
            .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| {
                this.phone_edit(cx, |o| o.framing = reset);
            }));
        rows.push(row("Show the Lock Screen clock", None, div().flex().items_center().gap(px(10.0)).child(clock)));
        rows.push(div().py(px(8.0)).flex().justify_end().child(reset_button).into_any_element());
        Group::titled("Look").rows(rows).footer("Uses this scene's settings from the other sections. Events are left out.")
    }

    fn phone_export_group(&mut self, cx: &mut Context<Self>) -> Group {
        let busy = self.phone.busy;
        let o = self.phone.options;
        let still = Button::new("phone-save-still")
            .label("Save Still...")
            .small()
            .disabled(busy)
            .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, _, cx| this.phone_export(false, cx)));
        let speeds = [1.0, 2.0, 4.0];
        let motion = segmented(
            "phone-motion",
            speeds.iter().map(|s| (SharedString::from(format!("{s}\u{d7}")), o.motion_speed == *s)).collect(),
            true,
            cx.listener(move |this: &mut Settings, i: &usize, _, cx| {
                let s = speeds[*i];
                this.phone_edit(cx, |o| o.motion_speed = s);
            }),
        );
        let movie = Button::new("phone-save-loop")
            .label("Save Loop...")
            .small()
            .disabled(busy)
            .tooltip("A 3-second MP4 that runs smoothly into itself")
            .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, _, cx| this.phone_export(true, cx)));
        let mut rows = vec![
            row("Still (PNG)", None, still),
            row("Loop motion", Some("1\u{d7} is the desktop's speed. Faster makes the motion show in a short loop."),
                div().w(px(150.0)).child(motion)),
            row("Loop (MP4)", None, movie),
        ];
        if busy || !self.phone.status.is_empty() {
            let mut status = div().py(px(8.0)).flex().items_center().gap(px(10.0));
            if let Some(p) = self.phone.progress.filter(|_| busy) {
                status = status.child(
                    div()
                        .w(px(80.0))
                        .h(px(4.0))
                        .rounded_full()
                        .bg(theme::white(0.15))
                        .child(div().h_full().rounded_full().bg(theme::accent()).w(px(80.0 * p as f32))),
                );
            }
            rows.push(
                status
                    .child(div().flex_1().text_size(px(12.0)).text_color(theme::secondary()).child(self.phone.status.clone()))
                    .into_any_element(),
            );
        }
        Group::titled("Export").rows(rows).footer(
            "The loop is 3 seconds that run smoothly into each other, for a video wallpaper or to share. Live Photos \
             need a Mac, which can make one from the same scene.",
        )
    }

    /// Asks where to save, then has the render thread write the still or the loop.
    fn phone_export(&mut self, movie: bool, cx: &mut Context<Self>) {
        let plan = self.phone_plan();
        let dir = std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join("Pictures")).unwrap_or_default();
        let ext = if movie { "mp4" } else { "png" };
        let suggested = format!("{}.{ext}", mobile_export::base_name(&plan));
        let path = cx.prompt_for_new_path(&dir, Some(&suggested));
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(mut path))) = path.await else { return };
            if path.extension().is_none() {
                path.set_extension(ext);
            }
            let _ = this.update(cx, |this, cx| {
                this.phone.busy = true;
                this.phone.progress = movie.then_some(0.0);
                this.phone.status = if movie { "Rendering the loop..." } else { "Rendering the still..." }.into();
                let _ = this.jobs.send(Job::Export { plan, path, movie });
                cx.notify();
            });
        })
        .detach();
    }

    /// A finished export: says so and shows the file in Explorer.
    pub fn phone_exported(&mut self, result: Result<PathBuf, String>) {
        self.phone.busy = false;
        self.phone.progress = None;
        match result {
            Ok(path) => {
                let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                self.phone.status = format!("Saved {name}.");
                let _ = std::process::Command::new("explorer").arg(format!("/select,{}", path.display())).spawn();
            }
            Err(e) => self.phone.status = format!("Couldn't save it: {e}"),
        }
    }

    /// A popup menu of choices that change the phone options.
    fn phone_menu(&mut self, key: &'static str, current: String, options: Vec<(String, bool)>,
                  pick: impl Fn(&mut Settings, usize, &mut Window, &mut Context<Settings>) + 'static,
                  cx: &mut Context<Self>) -> AnyElement {
        let view = cx.entity().downgrade();
        let pick = Rc::new(pick);
        Button::new(SharedString::from(format!("menu-{key}")))
            .label(current)
            .ghost()
            .small()
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                for (i, (title, checked)) in options.iter().enumerate() {
                    let view = view.clone();
                    let pick = pick.clone();
                    menu = menu.item(PopupMenuItem::new(title.clone()).checked(*checked).on_click(move |_, window, cx| {
                        let pick = pick.clone();
                        let _ = view.update(cx, |this, cx| {
                            pick(this, i, window, cx);
                            cx.notify();
                        });
                    }));
                }
                menu
            })
            .into_any_element()
    }
}

/// Roughly where the Lock Screen puts the date and the time.
fn clock_guide(size: (f32, f32)) -> Div {
    let (w, h) = size;
    // the text follows the height, until a custom size narrower than any iPhone would cut it off
    let scale = h.min(w * 2.2);
    div()
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .flex()
        .flex_col()
        .items_center()
        .pt(px(h * 0.1))
        .text_color(theme::white(0.85))
        .font_weight(FontWeight::SEMIBOLD)
        .child(div().text_size(px(scale * 0.022)).child(crate::system::lock_screen_date()))
        .child(div().text_size(px(scale * 0.12)).line_height(px(scale * 0.14)).child("9:41"))
}
