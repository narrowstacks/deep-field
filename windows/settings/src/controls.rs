//! The inspector's building blocks, after Controls.swift and Theme.swift: grouped boxes with a
//! small monospaced caps header, rows with a title on the left and the control on the right,
//! sliders with their value beside them, segmented pickers and color swatches.

use std::rc::Rc;

use deepfield::config::{Frequency, WallpaperConfig};
use deepfield::palette::Rgb;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::color_picker::{ColorPicker, ColorPickerEvent, ColorPickerState};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::slider::{Slider, SliderEvent, SliderState};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::Sizable;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;

use crate::app::Settings;
use crate::model::frequency_title;
use crate::theme;

pub type Fmt = fn(f64) -> String;

pub fn f2(v: f64) -> String {
    format!("{v:.2}")
}
pub fn f1(v: f64) -> String {
    format!("{v:.1}")
}
pub fn f0(v: f64) -> String {
    format!("{v:.0}")
}
pub fn deg(v: f64) -> String {
    format!("{v:.0}\u{b0}")
}
pub fn min1(v: f64) -> String {
    format!("{v:.1} min")
}
pub fn min0(v: f64) -> String {
    format!("{v:.0} min")
}
pub fn sec1(v: f64) -> String {
    format!("{v:.1} s")
}
pub fn x2(v: f64) -> String {
    format!("{v:.2}x")
}
pub fn x1(v: f64) -> String {
    format!("{v:.1}x")
}
pub fn km(v: f64) -> String {
    format!("{v:.0} km")
}

/// A slider bound to one number in the config.
pub struct SliderSpec {
    pub key: &'static str,
    pub title: &'static str,
    pub get: fn(&WallpaperConfig) -> f64,
    pub set: fn(&mut WallpaperConfig, f64),
    pub lo: f64,
    pub hi: f64,
    pub fmt: Fmt,
    pub help: Option<&'static str>,
}

impl SliderSpec {
    pub fn help(mut self, text: &'static str) -> Self {
        self.help = Some(text);
        self
    }
}

/// `slider!("Disk size", disk_size, 8.0, 18.0, f1)`: a SliderSpec for a config field.
#[macro_export]
macro_rules! slider {
    ($title:expr, $field:ident, $lo:expr, $hi:expr) => {
        $crate::slider!($title, $field, $lo, $hi, $crate::controls::f2)
    };
    ($title:expr, $field:ident, $lo:expr, $hi:expr, $fmt:expr) => {
        $crate::controls::SliderSpec {
            key: stringify!($field),
            title: $title,
            get: |c| c.$field,
            set: |c, v| c.$field = v,
            lo: $lo,
            hi: $hi,
            fmt: $fmt,
            help: None,
        }
    };
}

/// A group of rows in a box, with a header above and a note below (a grouped Form section).
pub struct Group {
    pub header: Option<AnyElement>,
    pub rows: Vec<AnyElement>,
    pub footer: Option<SharedString>,
}

impl Group {
    pub fn new(header: impl Into<Option<AnyElement>>) -> Group {
        Group { header: header.into(), rows: Vec::new(), footer: None }
    }
    pub fn titled(title: &str) -> Group {
        Group::new(Some(group_header(title).into_any_element()))
    }
    pub fn row(mut self, row: AnyElement) -> Group {
        self.rows.push(row);
        self
    }
    pub fn rows(mut self, rows: impl IntoIterator<Item = AnyElement>) -> Group {
        self.rows.extend(rows);
        self
    }
    pub fn footer(mut self, text: impl Into<SharedString>) -> Group {
        self.footer = Some(text.into());
        self
    }
    pub fn into_element(self) -> AnyElement {
        let n = self.rows.len();
        let rows = self.rows.into_iter().enumerate().map(|(i, r)| {
            div()
                .mx(px(10.0))
                .when(i + 1 < n, |d| d.border_b_1().border_color(theme::white(0.07)))
                .child(r)
        });
        div()
            .flex()
            .flex_col()
            .gap(px(6.0))
            .when_some(self.header, |d, h| d.child(div().px(px(10.0)).child(h)))
            .when(n > 0, |d| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .bg(theme::group_bg())
                        .border_1()
                        .border_color(theme::white(0.07))
                        .rounded(px(7.0))
                        .children(rows),
                )
            })
            .when_some(self.footer, |d, f| d.child(footer_text(f)))
            .into_any_element()
    }
}

/// A group title: small monospaced caps in the secondary color.
pub fn group_header(title: &str) -> Div {
    div()
        .font_family(theme::MONO)
        .text_size(px(10.5))
        .font_weight(FontWeight::MEDIUM)
        .text_color(theme::secondary())
        .child(spaced_caps(title))
}

/// Caps with a little letter spacing, which GPUI text doesn't set on its own.
fn spaced_caps(title: &str) -> String {
    title.to_uppercase().chars().map(|c| c.to_string()).collect::<Vec<_>>().join("\u{200a}")
}

pub fn footer_text(text: impl Into<SharedString>) -> Div {
    div().px(px(10.0)).text_size(px(12.0)).text_color(theme::secondary()).child(text.into())
}

/// A title on the left, a control on the right.
pub fn row(title: impl Into<SharedString>, help: Option<&'static str>, control: impl IntoElement) -> AnyElement {
    let title: SharedString = title.into();
    let id = SharedString::from(format!("row-{title}"));
    div()
        .min_h(px(38.0))
        .py(px(6.0))
        .flex()
        .items_center()
        .justify_between()
        .gap(px(12.0))
        .child(label(id, title, help))
        .child(control)
        .into_any_element()
}

fn label(id: SharedString, title: SharedString, help: Option<&'static str>) -> AnyElement {
    match help {
        Some(h) => div()
            .id(id)
            .flex_shrink_0()
            .child(title)
            .tooltip(move |window, cx| Tooltip::new(h).build(window, cx))
            .into_any_element(),
        None => div().flex_shrink_0().child(title).into_any_element(),
    }
}

/// A segmented picker; `on_select` gets the index picked.
pub fn segmented(id: &'static str, items: Vec<(SharedString, bool)>, small: bool,
                 on_select: impl Fn(&usize, &mut Window, &mut App) + 'static) -> AnyElement {
    let on_select = Rc::new(on_select);
    div()
        .w_full()
        .flex()
        .p(px(2.0))
        .gap(px(2.0))
        .rounded(px(6.0))
        .bg(theme::control_bg())
        .border_1()
        .border_color(theme::white(0.06))
        .children(items.into_iter().enumerate().map(move |(i, (title, selected))| {
            let on_select = on_select.clone();
            div()
                .id(SharedString::from(format!("{id}-{i}")))
                .flex_1()
                .min_w(px(0.0))
                .h(px(if small { 20.0 } else { 24.0 }))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(4.0))
                .text_size(px(if small { 11.0 } else { 12.5 }))
                .whitespace_nowrap()
                .when(selected, |d| d.bg(theme::control_selected()).text_color(theme::text()).font_weight(FontWeight::MEDIUM))
                .when(!selected, |d| d.text_color(theme::white(0.75)).hover(|s| s.bg(theme::white(0.05))).cursor_pointer())
                .child(title)
                .on_click(move |_, window, cx| on_select(&i, window, cx))
        }))
        .into_any_element()
}

pub fn to_hsla(c: Rgb) -> Hsla {
    Rgba { r: c.r.clamp(0.0, 1.0), g: c.g.clamp(0.0, 1.0), b: c.b.clamp(0.0, 1.0), a: 1.0 }.into()
}

/// Picks are stored to three decimals, like the Mac's.
pub fn from_hsla(h: Hsla) -> Rgb {
    let c = h.to_rgb();
    let r = |v: f32| (v.clamp(0.0, 1.0) * 1000.0).round() / 1000.0;
    deepfield::palette::rgb(r(c.r), r(c.g), r(c.b))
}

fn close(a: Rgb, b: Rgb) -> bool {
    (a.r - b.r).abs() < 0.004 && (a.g - b.g).abs() < 0.004 && (a.b - b.b).abs() < 0.004
}

pub struct Swatch {
    pub name: &'static str,
    pub colors: Vec<Rgb>,
    pub selected: bool,
    pub apply: Rc<dyn Fn(&mut WallpaperConfig)>,
}

impl Settings {
    pub fn slider_row(&mut self, s: SliderSpec, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let value = (s.get)(self.config());
        let (lo, hi) = (s.lo as f32, s.hi as f32);
        let step = (hi - lo) / 2000.0;
        let existing = self.sliders.get(s.key).filter(|e| {
            let st = e.read(cx);
            st.min_value() == lo && st.max_value() == hi
        });
        let state = match existing {
            Some(e) => {
                let e = e.clone();
                if (e.read(cx).value().start() - value as f32).abs() > step {
                    e.update(cx, |st, cx| st.set_value(value as f32, window, cx));
                }
                e
            }
            None => {
                let e = cx.new(|_| SliderState::new().min(lo).max(hi).step(step).default_value(value as f32));
                let set = s.set;
                self.subscriptions.push(cx.subscribe(&e, move |this: &mut Settings, _, ev: &SliderEvent, cx| {
                    // the slider works in f32; four decimals keep the saved file readable
                    let v = match ev {
                        SliderEvent::Change(v) | SliderEvent::Release(v) => (v.start() as f64 * 1e4).round() / 1e4,
                    };
                    this.edit(cx, |c| set(c, v));
                }));
                self.sliders.insert(s.key, e.clone());
                e
            }
        };
        let control = div()
            .flex()
            .items_center()
            .gap(px(10.0))
            .child(div().w(px(150.0)).child(Slider::new(&state)))
            .child(
                div()
                    .w(px(56.0))
                    .flex()
                    .justify_end()
                    .text_color(theme::secondary())
                    .whitespace_nowrap()
                    .child((s.fmt)(value)),
            );
        row(s.title, s.help, control)
    }

    pub fn toggle_row(&mut self, key: &'static str, title: impl Into<SharedString>, value: bool,
                      set: fn(&mut WallpaperConfig, bool), help: Option<&'static str>, cx: &mut Context<Self>) -> AnyElement {
        let switch = Switch::new(SharedString::from(format!("switch-{key}")))
            .checked(value)
            .color(theme::accent())
            .on_click(cx.listener(move |this: &mut Settings, on: &bool, _, cx| {
                let on = *on;
                this.edit(cx, |c| set(c, on));
            }));
        row(title, help, switch)
    }

    /// A popup menu of named options.
    pub fn picker_row<T: Copy + PartialEq + 'static>(&mut self, key: &'static str, title: impl Into<SharedString>,
                                                      value: T, options: &'static [T], name: fn(T) -> &'static str,
                                                      set: fn(&mut WallpaperConfig, T), help: Option<&'static str>,
                                                      cx: &mut Context<Self>) -> AnyElement {
        let names: Vec<(String, bool)> = options.iter().map(|o| (name(*o).to_string(), *o == value)).collect();
        let picker = self.menu_button(key, name(value).to_string(), names, move |c, i| set(c, options[i]), cx);
        row(title, help, picker)
    }

    /// A popup menu whose current entry is worked out by the caller (presets with a Custom entry).
    pub fn menu_button(&mut self, key: &'static str, current: String, options: Vec<(String, bool)>,
                       pick: impl Fn(&mut WallpaperConfig, usize) + 'static, cx: &mut Context<Self>) -> AnyElement {
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
                    menu = menu.item(PopupMenuItem::new(title.clone()).checked(*checked).on_click(move |_, _, cx| {
                        let pick = pick.clone();
                        let _ = view.update(cx, |this, cx| this.edit(cx, |c| pick(c, i)));
                    }));
                }
                menu
            })
            .into_any_element()
    }

    /// Frequency segments stacked under their title, so they fit the inspector's width.
    pub fn frequency_row(&mut self, key: &'static str, title: &'static str, value: Frequency,
                         set: fn(&mut WallpaperConfig, Frequency), help: Option<&'static str>,
                         cx: &mut Context<Self>) -> AnyElement {
        let items = Frequency::ALL.iter().map(|f| (SharedString::from(frequency_title(*f)), *f == value)).collect();
        let seg = segmented(key, items, false, cx.listener(move |this: &mut Settings, i: &usize, _, cx| {
            let f = Frequency::ALL[*i];
            this.edit(cx, |c| set(c, f));
        }));
        div()
            .py(px(8.0))
            .flex()
            .flex_col()
            .gap(px(6.0))
            .child(label(SharedString::from(format!("row-{key}")), title.into(), help))
            .child(seg)
            .into_any_element()
    }

    /// A segmented picker under its title (pixel size, color levels).
    pub fn segmented_row(&mut self, key: &'static str, title: &'static str, items: Vec<(String, bool)>,
                         pick: impl Fn(&mut WallpaperConfig, usize) + 'static, cx: &mut Context<Self>) -> AnyElement {
        let items = items.into_iter().map(|(t, s)| (SharedString::from(t), s)).collect();
        let seg = segmented(key, items, false, cx.listener(move |this: &mut Settings, i: &usize, _, cx| {
            let i = *i;
            this.edit(cx, |c| pick(c, i));
        }));
        div().py(px(8.0)).flex().flex_col().gap(px(6.0)).child(title).child(seg).into_any_element()
    }

    pub fn stepper_row(&mut self, key: &'static str, label_text: String, value: i64, lo: i64, hi: i64,
                       set: fn(&mut WallpaperConfig, i64), help: Option<&'static str>, cx: &mut Context<Self>) -> AnyElement {
        let button = |id: String, text: &'static str, enabled: bool, delta: i64, cx: &mut Context<Self>| {
            div()
                .id(SharedString::from(id))
                .w(px(28.0))
                .h(px(22.0))
                .flex()
                .items_center()
                .justify_center()
                .text_size(px(14.0))
                .rounded(px(5.0))
                .text_color(if enabled { theme::text() } else { theme::white(0.25) })
                .when(enabled, |d| d.cursor_pointer().hover(|s| s.bg(theme::white(0.08))))
                .child(text)
                .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| {
                    if enabled {
                        this.edit(cx, |c| set(c, (value + delta).clamp(lo, hi)));
                    }
                }))
        };
        let control = div()
            .flex()
            .items_center()
            .rounded(px(5.0))
            .bg(theme::control_bg())
            .child(button(format!("{key}-minus"), "\u{2212}", value > lo, -1, cx))
            .child(div().w(px(1.0)).h(px(14.0)).bg(theme::white(0.12)))
            .child(button(format!("{key}-plus"), "+", value < hi, 1, cx));
        row(label_text, help, control)
    }

    pub fn color_row(&mut self, key: &'static str, title: &'static str, value: Rgb,
                     set: fn(&mut WallpaperConfig, Rgb), window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let state = match self.colors.get(key) {
            Some(e) => {
                let e = e.clone();
                let shown = e.read(cx).value().map(from_hsla);
                if !shown.is_some_and(|s| close(s, value)) {
                    e.update(cx, |st, cx| st.set_value(to_hsla(value), window, cx));
                }
                e
            }
            None => {
                let e = cx.new(|cx| ColorPickerState::new(window, cx).default_value(to_hsla(value)));
                self.subscriptions.push(cx.subscribe(&e, move |this: &mut Settings, _, ev: &ColorPickerEvent, cx| {
                    if let ColorPickerEvent::Change(Some(h)) = ev {
                        let v = from_hsla(*h);
                        this.edit(cx, |c| set(c, v));
                    }
                }));
                self.colors.insert(key, e.clone());
                e
            }
        };
        row(title, None, ColorPicker::new(&state).small())
    }

    /// Color presets as swatch buttons, three to a row.
    pub fn swatch_grid(&mut self, key: &'static str, items: Vec<Swatch>, cx: &mut Context<Self>) -> AnyElement {
        let cells: Vec<AnyElement> = items
            .into_iter()
            .enumerate()
            .map(|(i, item)| {
                let apply = item.apply.clone();
                div()
                    .id(SharedString::from(format!("{key}-swatch-{i}")))
                    .flex_1()
                    .min_w(px(0.0))
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .bg(theme::white(0.06))
                    .border_color(if item.selected { theme::accent() } else { theme::white(0.1) })
                    // the thicker selected border takes from the padding, so nothing shifts
                    .when(item.selected, |d| d.border_2().p(px(5.0)))
                    .when(!item.selected, |d| d.border_1().p(px(6.0)).hover(|s| s.bg(theme::white(0.1))))
                    .cursor_pointer()
                    .child(div().flex().flex_none().children(
                        item.colors.iter().map(|c| div().w(px(10.0)).h(px(10.0)).bg(to_hsla(*c))),
                    ))
                    .child(div().text_size(px(11.0)).whitespace_nowrap().overflow_hidden().text_ellipsis().child(item.name))
                    .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| {
                        let apply = apply.clone();
                        this.edit(cx, move |c| apply(c));
                    }))
                    .into_any_element()
            })
            .collect();
        let mut rows = Vec::new();
        let mut it = cells.into_iter().peekable();
        while it.peek().is_some() {
            let mut row: Vec<AnyElement> = it.by_ref().take(3).collect();
            while row.len() < 3 {
                row.push(div().flex_1().into_any_element());
            }
            rows.push(div().flex().gap(px(6.0)).children(row));
        }
        div().py(px(8.0)).flex().flex_col().gap(px(6.0)).children(rows).into_any_element()
    }

    /// A row of small buttons after a title (framing presets, shuffles, seeds).
    pub fn buttons_row(&mut self, title: impl Into<SharedString>, buttons: Vec<(&'static str, Rc<dyn Fn(&mut Settings, &mut Context<Settings>)>)>,
                       cx: &mut Context<Self>) -> AnyElement {
        let title: SharedString = title.into();
        let controls = div().flex().gap(px(6.0)).children(buttons.into_iter().map(|(text, action)| {
            Button::new(SharedString::from(format!("btn-{title}-{text}")))
                .label(text)
                .small()
                .on_click(cx.listener(move |this: &mut Settings, _: &ClickEvent, _, cx| action(this, cx)))
        }));
        row(title, None, controls)
    }
}
