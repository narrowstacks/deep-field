//! The Presets menu (UI/PresetsMenu.swift and the panels in Config/UserPresets.swift): apply a
//! saved preset, save the current settings, import and export `.deepfield` files, rename,
//! choose which bring Live Earth's place, or delete.

use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

use deepfield::presets::{UserPreset, FILE_EXTENSION};
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::{Sizable, WindowExt as _};
use gpui_kit::*;

use crate::app::Settings;
use crate::theme;

const PLACE_TITLE: &str = "Include Live Earth's place";
const PLACE_HELP: &str = "The latitude and longitude Live Earth is centered on, which can be where you are";

/// A dialog's body text.
fn note(text: impl Into<SharedString>) -> Div {
    div().text_size(px(12.5)).text_color(theme::secondary()).child(text.into())
}

/// How a dialog's action button looks, and which button Enter presses.
#[derive(Clone, Copy, PartialEq)]
enum Action {
    /// filled; Enter does it
    Normal,
    /// red; Enter does it (the Mac's Delete)
    Destructive,
    /// red, with Cancel filled and Enter cancelling, for a choice that can't be undone (the
    /// Mac's Replace), so pressing Enter twice never makes it
    CancelFirst,
}

/// Cancel and the dialog's own action, at the bottom right.
fn footer(ok: &'static str, action: Action, on_ok: Rc<dyn Fn(&mut Window, &mut App)>) -> Div {
    let cancel = Button::new("cancel").label("Cancel").small().on_click(|_, window, cx| window.close_dialog(cx));
    let ok_button = Button::new("ok").label(ok).small().on_click(move |_, window, cx| on_ok(window, cx));
    let (cancel, ok_button) = match action {
        Action::Normal => (cancel, ok_button.primary()),
        Action::Destructive => (cancel, ok_button.danger()),
        Action::CancelFirst => (cancel.primary(), ok_button.danger()),
    };
    div().flex().justify_end().gap(px(8.0)).child(cancel).child(ok_button)
}

impl Settings {
    /// The menu button: the current preset's name, or "Presets".
    pub fn render_presets_menu(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let current = self.presets.current(self.config()).map(|p| p.id.clone());
        let label = current.as_ref().and_then(|id| self.presets.by_id(id)).map_or("Presets".to_string(), |p| p.name.clone());
        let list: Rc<Vec<(String, String, bool)>> =
            Rc::new(self.presets.presets.iter().map(|p| (p.id.clone(), p.name.clone(), p.includes_place)).collect());
        let view = cx.entity().downgrade();
        // each entry runs `f` on the window's view, with the window
        let act = move |f: Rc<dyn Fn(&mut Settings, &mut Window, &mut Context<Settings>)>| {
            let view = view.clone();
            move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let f = f.clone();
                let _ = view.update(cx, |this, cx| f(this, window, cx));
            }
        };
        Button::new("presets-menu")
            .label(label)
            .ghost()
            .small()
            .dropdown_caret(true)
            .tooltip("Save, apply, import and export your customizations")
            .dropdown_menu(move |mut menu, window, cx| {
                if list.is_empty() {
                    menu = menu.item(PopupMenuItem::label("No saved presets yet"));
                }
                for (id, name, _) in list.iter() {
                    let id = id.clone();
                    menu = menu.item(PopupMenuItem::new(name.clone()).checked(current.as_ref() == Some(&id)).on_click(act(Rc::new(
                        move |this, _, cx| this.apply_preset(&id, cx),
                    ))));
                }
                menu = menu.separator();
                menu = menu.item(PopupMenuItem::new("Save Current Settings as Preset\u{2026}").on_click(act(Rc::new(|this, w, cx| this.prompt_save_preset(w, cx)))));
                menu = menu.item(PopupMenuItem::new("Import Preset\u{2026}").on_click(act(Rc::new(|this, _, cx| this.prompt_import_presets(cx)))));
                let (l, a) = (list.clone(), act.clone());
                menu = menu.submenu("Export", window, cx, move |mut m, _, _| {
                    m = m.item(PopupMenuItem::new("Current Settings\u{2026}").on_click(a(Rc::new(|this, w, cx| this.prompt_export_preset(None, w, cx)))));
                    if !l.is_empty() {
                        m = m.separator();
                    }
                    for (id, name, _) in l.iter() {
                        let id = id.clone();
                        m = m.item(PopupMenuItem::new(format!("{name}\u{2026}")).on_click(a(Rc::new(move |this, w, cx| this.prompt_export_preset(Some(&id), w, cx)))));
                    }
                    m
                });
                if !list.is_empty() {
                    let (l, a) = (list.clone(), act.clone());
                    menu = menu.submenu("Rename", window, cx, move |mut m, _, _| {
                        for (id, name, _) in l.iter() {
                            let id = id.clone();
                            m = m.item(PopupMenuItem::new(format!("{name}\u{2026}")).on_click(a(Rc::new(move |this, w, cx| this.prompt_rename_preset(&id, w, cx)))));
                        }
                        m
                    });
                    let (l, a) = (list.clone(), act.clone());
                    menu = menu.submenu("Include Live Earth's Place", window, cx, move |mut m, _, _| {
                        for (id, name, on) in l.iter() {
                            let (id, on) = (id.clone(), *on);
                            m = m.item(PopupMenuItem::new(name.clone()).checked(on).on_click(a(Rc::new(move |this, _, cx| {
                                this.presets.set_includes_place(&id, !on);
                                cx.notify();
                            }))));
                        }
                        m
                    });
                    let (l, a) = (list.clone(), act.clone());
                    menu = menu.submenu("Delete", window, cx, move |mut m, _, _| {
                        for (id, name, _) in l.iter() {
                            let id = id.clone();
                            m = m.item(PopupMenuItem::new(format!("{name}\u{2026}")).on_click(a(Rc::new(move |this, w, cx| this.confirm_delete_preset(&id, w, cx)))));
                        }
                        m
                    });
                }
                menu
            })
            .into_any_element()
    }

    pub fn apply_preset(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(p) = self.presets.by_id(id).cloned() else { return };
        self.edit(cx, |c| *c = p.applied(c));
        self.flash(format!("Applied \u{201C}{}\u{201D}", p.name));
    }

    /// Asks for a name, then saves the current settings under it, asking again before replacing one.
    pub(crate) fn prompt_save_preset(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let name = self.presets.unused_name(self.config().scene.title());
        let input = cx.new(|cx| InputState::new(window, cx).default_value(name).placeholder("Preset name"));
        // off to start with, since the place can be this computer's location
        let place = Rc::new(Cell::new(false));
        let first = Cell::new(true);
        let view = cx.entity().downgrade();
        let save: Rc<dyn Fn(&mut Window, &mut App)> = {
            let (input, place) = (input.clone(), place.clone());
            Rc::new(move |window, cx| {
                let typed = input.read(cx).value().trim().to_string();
                let place = place.get();
                let _ = view.update(cx, |this, cx| {
                    let name = if typed.is_empty() { this.presets.unused_name("Untitled") } else { typed };
                    if let Some(existing) = this.presets.named(&name).cloned() {
                        // the replace question goes over this dialog; Cancel there comes back here
                        this.confirm_replace_preset(existing, place, window, cx);
                    } else {
                        window.close_dialog(cx);
                        this.save_preset(&name, place, cx);
                    }
                });
            })
        };
        window.open_dialog(cx, move |dialog, window, cx| {
            if first.replace(false) {
                input.focus_handle(cx).focus(window, cx);
            }
            let p = place.clone();
            let s = save.clone();
            dialog
                .title("Save Preset")
                .w(px(380.0))
                .on_ok(move |_, window, cx| {
                    s(window, cx);
                    false
                })
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(10.0))
                        .child(note("Save the current scene and its look under a name. Frame rate and lock screen settings aren't included."))
                        .child(Input::new(&input))
                        .child(Checkbox::new("preset-place").label(PLACE_TITLE).checked(place.get()).tooltip(PLACE_HELP).on_click(
                            move |on, window, _| {
                                p.set(*on);
                                window.refresh();
                            },
                        )),
                )
                .footer(footer("Save", Action::Normal, save.clone()))
        });
    }

    fn save_preset(&mut self, name: &str, include_place: bool, cx: &mut Context<Self>) {
        let c = self.config().clone();
        let p = self.presets.save_current(name, &c, Some(include_place));
        self.flash(format!("Saved \u{201C}{}\u{201D}", p.name));
        cx.notify();
    }

    fn confirm_replace_preset(&mut self, existing: UserPreset, place: bool, window: &mut Window, cx: &mut Context<Self>) {
        let view = cx.entity().downgrade();
        let name = existing.name.clone();
        let replace: Rc<dyn Fn(&mut Window, &mut App)> = Rc::new(move |window, cx| {
            // this question, then the naming one under it
            window.close_dialog(cx);
            window.close_dialog(cx);
            let _ = view.update(cx, |this, cx| this.save_preset(&name, place, cx));
        });
        let title = format!("Replace \u{201C}{}\u{201D}?", existing.name);
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title(title.clone())
                .w(px(380.0))
                // Enter cancels
                .on_ok(|_, _, _| true)
                .child(note("A preset with this name already exists. Replacing it can't be undone."))
                .footer(footer("Replace", Action::CancelFirst, replace.clone()))
        });
    }

    fn prompt_rename_preset(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(p) = self.presets.by_id(id).cloned() else { return };
        let input = cx.new(|cx| InputState::new(window, cx).default_value(p.name.clone()));
        let problem: Rc<Cell<Option<&'static str>>> = Rc::new(Cell::new(None));
        let first = Cell::new(true);
        let view = cx.entity().downgrade();
        let id = id.to_string();
        let rename: Rc<dyn Fn(&mut Window, &mut App)> = {
            let (input, problem) = (input.clone(), problem.clone());
            Rc::new(move |window, cx| {
                let name = input.read(cx).value().to_string();
                let renamed = view
                    .update(cx, |this, cx| {
                        let ok = this.presets.rename(&id, &name);
                        if !ok {
                            problem.set(Some(if this.presets.named(&name).is_none() {
                                "Enter a name for the preset."
                            } else {
                                "Another preset already has that name."
                            }));
                        }
                        cx.notify();
                        ok
                    })
                    .unwrap_or(true);
                if renamed {
                    window.close_dialog(cx);
                } else {
                    window.refresh();
                }
            })
        };
        window.open_dialog(cx, move |dialog, window, cx| {
            if first.replace(false) {
                input.focus_handle(cx).focus(window, cx);
            }
            let r = rename.clone();
            dialog
                .title("Rename Preset")
                .w(px(340.0))
                .on_ok(move |_, window, cx| {
                    r(window, cx);
                    false
                })
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(8.0))
                        .child(Input::new(&input))
                        .children(problem.get().map(|p| note(p).text_color(theme::warning()))),
                )
                .footer(footer("Rename", Action::Normal, rename.clone()))
        });
    }

    fn confirm_delete_preset(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(p) = self.presets.by_id(id).cloned() else { return };
        let view = cx.entity().downgrade();
        let id = id.to_string();
        let delete: Rc<dyn Fn(&mut Window, &mut App)> = Rc::new(move |window, cx| {
            window.close_dialog(cx);
            let _ = view.update(cx, |this, cx| {
                this.presets.delete(&id);
                cx.notify();
            });
        });
        let title = format!("Delete \u{201C}{}\u{201D}?", p.name);
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title(title.clone())
                .w(px(340.0))
                .on_ok({
                    let d = delete.clone();
                    move |_, window, cx| {
                        d(window, cx);
                        false
                    }
                })
                .child(note("Your current settings stay as they are."))
                .footer(footer("Delete", Action::Destructive, delete.clone()))
        });
    }

    /// Adds the chosen `.deepfield` files; a single one is applied too, as on the Mac.
    pub(crate) fn prompt_import_presets(&mut self, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some("Choose Deep Field preset files to add.".into()),
        });
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            let _ = this.update(cx, |this, cx| this.import_presets(paths, cx));
        })
        .detach();
    }

    fn import_presets(&mut self, paths: Vec<PathBuf>, cx: &mut Context<Self>) {
        let mut failed = Vec::new();
        let mut last = None;
        for path in &paths {
            match self.presets.import_file(path) {
                Ok(p) => last = Some(p),
                Err(_) => failed.push(path.file_name().map_or(String::new(), |n| n.to_string_lossy().into_owned())),
            }
        }
        if paths.len() == 1 {
            if let Some(p) = last {
                self.apply_preset(&p.id, cx);
            }
        }
        if !failed.is_empty() {
            self.flash(format!("Couldn't import {}: not a Deep Field preset", failed.join(", ")));
        }
        cx.notify();
    }

    /// Exports a preset, or the current settings when `id` is None: first whether to bring the
    /// place (the Mac's save panel has that checkbox), then where.
    pub(crate) fn prompt_export_preset(&mut self, id: Option<&str>, window: &mut Window, cx: &mut Context<Self>) {
        let preset = match id.and_then(|id| self.presets.by_id(id)) {
            Some(p) => p.clone(),
            None => {
                let c = self.config().clone();
                let name = self.presets.current(&c).map_or(c.scene.title().to_string(), |p| p.name.clone());
                UserPreset::new(&name, c)
            }
        };
        let place = Rc::new(Cell::new(false));
        let view = cx.entity().downgrade();
        let choose: Rc<dyn Fn(&mut Window, &mut App)> = {
            let (preset, place) = (preset.clone(), place.clone());
            Rc::new(move |window, cx| {
                window.close_dialog(cx);
                let (preset, place) = (preset.clone(), place.get());
                let _ = view.update(cx, |this, cx| this.export_preset_to_file(preset, place, cx));
            })
        };
        let title = format!("Export \u{201C}{}\u{201D}", preset.name);
        window.open_dialog(cx, move |dialog, _, _| {
            let p = place.clone();
            let c = choose.clone();
            dialog
                .title(title.clone())
                .w(px(380.0))
                .on_ok(move |_, window, cx| {
                    c(window, cx);
                    false
                })
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(10.0))
                        .child(note("Anyone with Deep Field can import this file."))
                        .child(Checkbox::new("export-place").label(PLACE_TITLE).checked(place.get()).tooltip(PLACE_HELP).on_click(
                            move |on, window, _| {
                                p.set(*on);
                                window.refresh();
                            },
                        )),
                )
                .footer(footer("Save As\u{2026}", Action::Normal, choose.clone()))
        });
    }

    fn export_preset_to_file(&mut self, preset: UserPreset, include_place: bool, cx: &mut Context<Self>) {
        let dir = std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join("Documents")).unwrap_or_default();
        // Windows file names can't hold these
        let safe: String = preset.name.chars().map(|ch| if r#"<>:"/\|?*"#.contains(ch) { '-' } else { ch }).collect();
        let suggested = format!("{safe}.{FILE_EXTENSION}");
        let path = cx.prompt_for_new_path(&dir, Some(&suggested));
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(mut path))) = path.await else { return };
            if path.extension().is_none() {
                path.set_extension(FILE_EXTENSION);
            }
            let written = std::fs::write(&path, preset.file_data(include_place));
            let _ = this.update(cx, |this, cx| {
                match written {
                    Ok(()) => this.flash(format!("Exported \u{201C}{}\u{201D}", preset.name)),
                    Err(e) => this.flash(format!("Couldn't export the preset: {e}")),
                }
                cx.notify();
            });
        })
        .detach();
    }
}
