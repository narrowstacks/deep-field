//! The Schedule section (UI/ScheduleTab.swift): rotate through presets and scenes, or switch at
//! set times on chosen days, each switch moving into the next with a transition. The wallpaper
//! runs it; this window edits schedule.json and shows what's on now.

use std::rc::Rc;

use deepfield::config::SceneKind;
use deepfield::schedule::{
    self, Mode, ScheduleEntry, ScheduleState, ScheduleTarget, SystemCalendar, WallpaperSchedule, FADES, INTERVALS,
};
use deepfield::transition::TransitionStyle;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::menu::{DropdownMenu, PopupMenu, PopupMenuItem};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::*;

use crate::app::Settings;
use crate::controls::{row, segmented, Group};

type Rows = Vec<AnyElement>;
use crate::system;
use crate::theme;

type Pick = Rc<dyn Fn(&mut WallpaperSchedule, usize)>;

/// A number as the Mac's `ConfigKeys.number` writes it: no trailing ".0".
fn number(v: f64) -> String {
    if v.fract() == 0.0 { format!("{}", v as i64) } else { format!("{v}") }
}

fn interval_title(minutes: f64) -> String {
    match minutes {
        m if m == 60.0 => "Hour".into(),
        m if m == 1440.0 => "Day".into(),
        m if m >= 120.0 && m % 60.0 == 0.0 => format!("{} hours", number(m / 60.0)),
        m => format!("{} min", number(m)),
    }
}

fn length_title(seconds: f64) -> String {
    if seconds == 0.0 { "Instant".into() } else { format!("{} s", number(seconds)) }
}

/// The usual values plus the current one, so a picker always has it to show.
fn including(values: &[f64], current: f64) -> Vec<f64> {
    let mut v = values.to_vec();
    if !v.contains(&current) {
        v.push(current);
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    }
    v
}

impl Settings {
    /// Every schedule change goes through here: continued from the old schedule (so a running
    /// rotation keeps its place) and written for the wallpaper, which runs it.
    pub fn edit_schedule(&mut self, cx: &mut Context<Self>, f: impl FnOnce(&mut WallpaperSchedule)) {
        let mut s = self.schedule.schedule.clone();
        f(&mut s);
        if self.schedule.set(s).is_some() {
            cx.notify();
        }
    }

    /// A popup menu that edits the schedule.
    fn schedule_menu(&mut self, key: SharedString, current: String, options: Vec<(String, bool)>, pick: Pick,
                     cx: &mut Context<Self>) -> AnyElement {
        let view = cx.entity().downgrade();
        Button::new(key)
            .label(current)
            .ghost()
            .small()
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                for (i, (title, checked)) in options.iter().enumerate() {
                    let (view, pick) = (view.clone(), pick.clone());
                    menu = menu.item(PopupMenuItem::new(title.clone()).checked(*checked).on_click(move |_, _, cx| {
                        let pick = pick.clone();
                        let _ = view.update(cx, |this, cx| this.edit_schedule(cx, |s| pick(s, i)));
                    }));
                }
                menu
            })
            .into_any_element()
    }
}

pub fn schedule_tab(s: &mut Settings, _w: &mut Window, cx: &mut Context<Settings>) -> Rows {
    let sch = s.schedule.schedule.clone();
    let presets = s.presets.presets.clone();

    // MARK: the schedule itself
    let enabled = Switch::new("schedule-enabled").checked(sch.enabled).color(theme::accent()).on_click(cx.listener(
        |this: &mut Settings, on: &bool, _, cx| {
            let on = *on;
            this.edit_schedule(cx, |s| s.enabled = on);
        },
    ));
    let mut rows = vec![row("Change the wallpaper on a schedule", None, enabled)];
    let mode = sch.mode;
    rows.push(segmented(
        "schedule-mode",
        [Mode::Rotate, Mode::Timed].iter().map(|m| (SharedString::from(m.title()), *m == mode)).collect(),
        false,
        cx.listener(|this: &mut Settings, i: &usize, _, cx| {
            let m = if *i == 0 { Mode::Rotate } else { Mode::Timed };
            this.edit_schedule(cx, |s| s.mode = m);
        }),
    ));
    if mode == Mode::Rotate {
        let values = including(&INTERVALS, sch.interval_minutes);
        let opts = values.iter().map(|v| (interval_title(*v), *v == sch.interval_minutes)).collect();
        let menu = s.schedule_menu("schedule-every".into(), interval_title(sch.interval_minutes), opts,
                                   Rc::new(move |s, i| s.interval_minutes = values[i]), cx);
        rows.push(row("Every", None, menu));
        let shuffle = Switch::new("schedule-shuffle").checked(sch.shuffle).color(theme::accent()).on_click(cx.listener(
            |this: &mut Settings, on: &bool, _, cx| {
                let on = *on;
                this.edit_schedule(cx, |s| s.shuffle = on);
            },
        ));
        rows.push(row("Shuffle", Some("A new order each time round, never showing the same look twice in a row"), shuffle));
    }
    let styles = TransitionStyle::ALL;
    let opts = styles.iter().map(|t| (t.title().to_string(), *t == sch.transition)).collect();
    let menu = s.schedule_menu("schedule-transition".into(), sch.transition.title().into(), opts,
                               Rc::new(move |s, i| s.transition = styles[i]), cx);
    rows.push(row("Transition", Some(sch.transition.help()), menu));
    let values = including(&FADES, sch.fade_seconds);
    let opts = values.iter().map(|v| (length_title(*v), *v == sch.fade_seconds)).collect();
    let menu = s.schedule_menu("schedule-length".into(), length_title(sch.fade_seconds), opts,
                               Rc::new(move |s, i| s.fade_seconds = values[i]), cx);
    rows.push(row("Length", Some("How long each switch takes"), menu));
    let state = ScheduleState::load_from(&ScheduleState::path());
    let status = schedule::status(&sch, s.config(), &presets, &state, schedule::now(), &SystemCalendar);
    let head = Group::titled("Schedule").rows(rows).footer(status);

    // MARK: the entries
    let mut entries: Vec<AnyElement> = Vec::new();
    if sch.entries.is_empty() {
        let note = if mode == Mode::Rotate {
            "Add presets or scenes to rotate through."
        } else {
            "Add presets or scenes and the times they start."
        };
        entries.push(div().py(px(8.0)).text_color(theme::secondary()).child(note).into_any_element());
    }
    let names = system::weekday_names();
    let first_day = system::first_weekday();
    for (i, e) in sch.entries.iter().enumerate() {
        entries.push(entry_row(s, e, i, mode, &presets, &names, first_day, cx));
    }
    let add = add_menu(s, &presets, cx);
    let mut bottom = div().flex().items_center().justify_between().py(px(6.0)).child(add);
    if mode == Mode::Rotate && sch.enabled && sch.entries.len() > 1 {
        bottom = bottom.child(
            Button::new("schedule-next")
                .label("Next Now")
                .small()
                .tooltip("Moves on to the next look and starts the interval over")
                .on_click(cx.listener(|this: &mut Settings, _: &ClickEvent, _, cx| {
                    if let Some(s) = this.schedule.schedule.skipped(schedule::now(), &SystemCalendar) {
                        this.edit_schedule(cx, |x| *x = s);
                    }
                })),
        );
    }
    entries.push(bottom.into_any_element());
    let footer = if mode == Mode::Rotate {
        "Presets bring their whole look; a scene keeps your current settings. Changes you make by hand stay until the next switch."
    } else {
        "Each one holds until the next starts, overnight too."
    };
    let list = Group::titled(if mode == Mode::Rotate { "Rotation" } else { "Times" }).rows(entries).footer(footer);
    vec![head.into_element(), list.into_element()]
}

/// The presets, then the scenes, each picking `pick(target)`.
fn targets_menu(mut menu: PopupMenu, presets: &[deepfield::presets::UserPreset], current: Option<&ScheduleTarget>,
                pick: Rc<dyn Fn(ScheduleTarget, &mut App)>) -> PopupMenu {
    menu = menu.item(PopupMenuItem::label("Presets"));
    if presets.is_empty() {
        menu = menu.item(PopupMenuItem::new("No saved presets yet").disabled(true));
    }
    for p in presets {
        let t = ScheduleTarget::Preset { id: p.id.clone() };
        let checked = current == Some(&t);
        let pick = pick.clone();
        menu = menu.item(PopupMenuItem::new(p.name.clone()).checked(checked).on_click(move |_, _, cx| pick(t.clone(), cx)));
    }
    menu = menu.separator().item(PopupMenuItem::label("Scenes"));
    for k in SceneKind::listed() {
        let t = ScheduleTarget::Scene { kind: k };
        let checked = current == Some(&t);
        let pick = pick.clone();
        menu = menu.item(PopupMenuItem::new(k.title()).checked(checked).on_click(move |_, _, cx| pick(t.clone(), cx)));
    }
    menu
}

fn add_menu(_s: &mut Settings, presets: &[deepfield::presets::UserPreset], cx: &mut Context<Settings>) -> AnyElement {
    let view = cx.entity().downgrade();
    let presets = presets.to_vec();
    Button::new("schedule-add")
        .label("Add")
        .small()
        .dropdown_caret(true)
        .dropdown_menu(move |menu, _, _| {
            let view = view.clone();
            targets_menu(menu, &presets, None, Rc::new(move |t, cx| {
                let _ = view.update(cx, |this, cx| {
                    this.edit_schedule(cx, |s| {
                        // a new timed entry starts an hour after the last one, so two don't land
                        // on the same time
                        let mut e = ScheduleEntry::new(t);
                        if let Some(last) = s.entries.last() {
                            e.minute = (last.minute + 60) % (24 * 60);
                        }
                        s.entries.push(e);
                    })
                });
            }))
        })
        .into_any_element()
}

#[allow(clippy::too_many_arguments)]
fn entry_row(_s: &mut Settings, e: &ScheduleEntry, index: usize, mode: Mode, presets: &[deepfield::presets::UserPreset],
             names: &[(String, String)], first_day: i64, cx: &mut Context<Settings>) -> AnyElement {
    let view = cx.entity().downgrade();
    let id = e.id.clone();
    // edits this entry, wherever it is in the list by then
    let edit = {
        let (view, id) = (view.clone(), id.clone());
        Rc::new(move |cx: &mut App, f: Rc<dyn Fn(&mut ScheduleEntry)>| {
            let id = id.clone();
            let _ = view.update(cx, |this, cx| {
                this.edit_schedule(cx, |s| {
                    if let Some(e) = s.entries.iter_mut().find(|e| e.id == id) {
                        f(e);
                    }
                })
            });
        })
    };

    let mut line = div().flex().items_center().gap(px(6.0));
    if mode == Mode::Timed {
        let minute = e.minute;
        let ed = edit.clone();
        line = line.child(
            Button::new(SharedString::from(format!("entry-time-{index}")))
                .label(schedule::time_of_day(minute))
                .ghost()
                .small()
                .dropdown_caret(true)
                .dropdown_menu(move |mut menu, window, cx| {
                    // an hour, then its minutes in fives (the current one is always there)
                    for hour in 0..24i64 {
                        let ed = ed.clone();
                        menu = menu.submenu(schedule::time_of_day(hour * 60), window, cx, move |mut m, _, _| {
                            let mut mins: Vec<i64> = (0..12).map(|i| hour * 60 + i * 5).collect();
                            if minute / 60 == hour && !mins.contains(&minute) {
                                mins.push(minute);
                                mins.sort();
                            }
                            for v in mins {
                                let ed = ed.clone();
                                m = m.item(PopupMenuItem::new(schedule::time_of_day(v)).checked(v == minute).on_click(
                                    move |_, _, cx| ed(cx, Rc::new(move |e: &mut ScheduleEntry| e.minute = v)),
                                ));
                            }
                            m
                        });
                    }
                    menu
                }),
        );
    }
    let deleted = matches!(&e.target, ScheduleTarget::Preset { id } if !presets.iter().any(|p| &p.id == id));
    let title = e.target.title(presets);
    let current = e.target.clone();
    let list = presets.to_vec();
    let ed = edit.clone();
    line = line.child(
        div().flex_1().min_w(px(0.0)).child(
            Button::new(SharedString::from(format!("entry-target-{index}")))
                .label(title)
                .ghost()
                .small()
                .dropdown_caret(true)
                .dropdown_menu(move |mut menu, _, _| {
                    if deleted {
                        menu = menu.item(PopupMenuItem::new("Deleted preset").checked(true)).separator();
                    }
                    let ed = ed.clone();
                    targets_menu(menu, &list, Some(&current), Rc::new(move |t, cx| {
                        ed(cx, Rc::new(move |e: &mut ScheduleEntry| e.target = t.clone()))
                    }))
                }),
        ),
    );
    let can_move_up = index > 0;
    let (v1, v2, id1, id2) = (view.clone(), view.clone(), id.clone(), id.clone());
    line = line.child(
        Button::new(SharedString::from(format!("entry-options-{index}")))
            .label("\u{22ef}")
            .ghost()
            .xsmall()
            .tooltip(format!("Entry {} options", index + 1))
            .dropdown_menu(move |mut menu, _, _| {
                if mode == Mode::Rotate {
                    let (v, id) = (v1.clone(), id1.clone());
                    menu = menu.item(PopupMenuItem::new("Move Up").disabled(!can_move_up).on_click(move |_, _, cx| {
                        let id = id.clone();
                        let _ = v.update(cx, |this, cx| {
                            this.edit_schedule(cx, |s| {
                                if let Some(i) = s.entries.iter().position(|e| e.id == id).filter(|&i| i > 0) {
                                    s.entries.swap(i, i - 1);
                                }
                            })
                        });
                    }));
                }
                let (v, id) = (v2.clone(), id2.clone());
                menu.item(PopupMenuItem::new("Remove").on_click(move |_, _, cx| {
                    let id = id.clone();
                    let _ = v.update(cx, |this, cx| this.edit_schedule(cx, |s| s.entries.retain(|e| e.id != id)));
                }))
            }),
    );

    let mut col = div().py(px(6.0)).flex().flex_col().gap(px(6.0)).child(line);
    if mode == Mode::Timed {
        // one toggle per day, starting on the locale's first weekday
        let mut days = div().flex().gap(px(4.0));
        for k in 0..7 {
            let day = (first_day - 1 + k) % 7 + 1;
            let on = e.weekdays.contains(&day);
            let only = on && e.weekdays.len() == 1;
            let (short, full) = names[(day - 1) as usize].clone();
            let ed = edit.clone();
            let mut b = Button::new(SharedString::from(format!("entry-{index}-day-{day}")))
                .label(short)
                .xsmall()
                .tooltip(full)
                // the last day left stays on, so the entry always starts somewhere
                .disabled(only)
                .on_click(move |_, _, cx| {
                    ed(cx, Rc::new(move |e: &mut ScheduleEntry| {
                        if e.weekdays.contains(&day) {
                            if e.weekdays.len() > 1 {
                                e.weekdays.remove(&day);
                            }
                        } else {
                            e.weekdays.insert(day);
                        }
                    }))
                });
            b = if on { b.primary() } else { b.ghost() };
            days = days.child(b);
        }
        col = col.child(days);
    }
    col.into_any_element()
}
