//! Changing the wallpaper over time (Config/Schedule.swift, Config/ScheduleStatus.swift and
//! App/Scheduler.swift). Rotate steps through the entries every `interval_minutes` (in order or
//! shuffled); Timed switches to each entry at its time of day on its weekdays, and holds it until
//! the next one. Each switch takes `fade_seconds`, in the `transition` style.
//!
//! The schedule is kept in %APPDATA%\DeepField\schedule.json, in the Mac's format, apart from the
//! look so presets never carry it. The wallpaper runs it and records the last switch in
//! schedule-state.json, which the Customize window reads for its status line.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::config::{SceneKind, WallpaperConfig};
use crate::config_store::dir;
use crate::customization::visible_settings;
use crate::presets::{new_id, UserPreset};
use crate::transition::TransitionStyle;

/// Times here count seconds from 2001-01-01 UTC, as Swift's `Date` encodes, so a schedule saved
/// by either app reads in the other.
pub const REFERENCE_UNIX: f64 = 978_307_200.0;

pub fn now() -> f64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0) - REFERENCE_UNIX
}

/// What an entry switches to: a saved preset (its whole look), or a scene (keeping the current
/// settings, as picking it in the gallery does). Encoded as Swift encodes the enum.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ScheduleTarget {
    #[serde(rename = "preset")]
    Preset {
        #[serde(rename = "_0")]
        id: String,
    },
    #[serde(rename = "scene")]
    Scene {
        #[serde(rename = "_0")]
        kind: SceneKind,
    },
}

impl ScheduleTarget {
    pub fn title(&self, presets: &[UserPreset]) -> String {
        match self {
            ScheduleTarget::Preset { id } => {
                presets.iter().find(|p| &p.id == id).map_or("Deleted preset".to_string(), |p| p.name.clone())
            }
            ScheduleTarget::Scene { kind } => kind.title().to_string(),
        }
    }

    /// The config this target makes from `current`, or None if its preset is gone.
    pub fn applied(&self, current: &WallpaperConfig, presets: &[UserPreset]) -> Option<WallpaperConfig> {
        match self {
            ScheduleTarget::Preset { id } => presets.iter().find(|p| &p.id == id).map(|p| p.applied(current)),
            ScheduleTarget::Scene { kind } => {
                if !kind.is_listed() {
                    return None;
                }
                let mut c = current.clone();
                c.set_scene(*kind);
                Some(c)
            }
        }
    }
}

fn all_days() -> BTreeSet<i64> {
    (1..=7).collect()
}
fn nine() -> i64 {
    9 * 60
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScheduleEntry {
    #[serde(default = "new_id")]
    pub id: String,
    pub target: ScheduleTarget,
    /// Timed mode: when it starts, in minutes after midnight, local time.
    #[serde(default = "nine")]
    pub minute: i64,
    /// Timed mode: the days it starts on, 1 = Sunday ... 7 = Saturday (as Swift's `Calendar`).
    #[serde(default = "all_days")]
    pub weekdays: BTreeSet<i64>,
}

impl ScheduleEntry {
    pub fn new(target: ScheduleTarget) -> ScheduleEntry {
        ScheduleEntry { id: new_id(), target, minute: nine(), weekdays: all_days() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Rotate,
    Timed,
}

impl Mode {
    pub fn title(self) -> &'static str {
        match self {
            Mode::Rotate => "Rotate",
            Mode::Timed => "At Set Times",
        }
    }
}

/// An entry removed while it was the current one, which stays current until its step ends.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Removed {
    pub entry: ScheduleEntry,
    pub step: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperSchedule {
    pub enabled: bool,
    pub mode: Mode,
    pub entries: Vec<ScheduleEntry>,
    pub interval_minutes: f64,
    pub shuffle: bool,
    pub fade_seconds: f64,
    pub transition: TransitionStyle,
    /// Rotation counts whole intervals from here, so the order survives relaunches.
    pub anchor: f64,
    /// Added to the step to get the place in the rotation, so an edit can move the current
    /// entry's place while the step, and with it the slot's key, stays the same.
    pub shift: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub removed: Option<Removed>,
}

impl Default for WallpaperSchedule {
    fn default() -> Self {
        WallpaperSchedule {
            enabled: false, mode: Mode::Rotate, entries: Vec::new(), interval_minutes: 60.0, shuffle: false,
            fade_seconds: 8.0, transition: TransitionStyle::Dissolve, anchor: now(), shift: 0, removed: None,
        }
    }
}

pub const INTERVALS: [f64; 9] = [1.0, 5.0, 15.0, 30.0, 60.0, 120.0, 240.0, 480.0, 1440.0];
pub const FADES: [f64; 7] = [0.0, 2.0, 4.0, 8.0, 15.0, 30.0, 60.0];

/// The entry that should be showing, and a key that changes exactly when a new switch is due (a
/// new rotation step, or a new timed start), so a relaunch or a manual edit in between doesn't
/// repeat one.
#[derive(Clone, Debug, PartialEq)]
pub struct Slot {
    pub entry: ScheduleEntry,
    pub key: String,
    /// When the next switch is due, if there is one.
    pub next: Option<f64>,
}

/// A small seeded generator, so a shuffle is the same on every launch (SplitMix in Swift).
struct SplitMix(u64);
impl SplitMix {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

impl WallpaperSchedule {
    /// Lenient, like the config: a key missing from an older save, or one that no longer
    /// decodes, keeps its default.
    pub fn decode(json: &str) -> Option<WallpaperSchedule> {
        let Value::Object(saved) = serde_json::from_str::<Value>(json).ok()? else { return None };
        let Value::Object(mut merged) = serde_json::to_value(WallpaperSchedule::default()).ok()? else { return None };
        let decodes = |m: &Map<String, Value>| serde_json::from_value::<WallpaperSchedule>(Value::Object(m.clone())).ok();
        for (k, v) in &saved {
            let mut trial = merged.clone();
            trial.insert(k.clone(), v.clone());
            if decodes(&trial).is_some() {
                merged = trial;
            }
        }
        decodes(&merged)
    }

    pub fn slot(&self, date: f64, cal: &dyn LocalCalendar) -> Option<Slot> {
        if self.entries.is_empty() {
            return None;
        }
        match self.mode {
            Mode::Rotate => Some(self.rotation_slot(date)),
            Mode::Timed => self.timed_slot(date, cal),
        }
    }

    fn interval(&self) -> f64 {
        self.interval_minutes.max(1.0) * 60.0
    }

    fn step(&self, date: f64) -> i64 {
        ((date - self.anchor) / self.interval()).floor() as i64
    }

    fn rotation_slot(&self, date: f64) -> Slot {
        let step = self.step(date);
        let entry = match &self.removed {
            Some(r) if r.step == step => r.entry.clone(),
            _ => self.entry_at_step(step),
        };
        Slot {
            key: format!("rotate {step} {} {:?}", entry.id, entry.target),
            entry,
            next: Some(self.anchor + (step + 1) as f64 * self.interval()),
        }
    }

    fn entry_at_step(&self, step: i64) -> ScheduleEntry {
        let n = self.entries.len() as i64;
        let place = step + self.shift;
        let index = place.rem_euclid(n) as usize;
        let i = if self.shuffle { Self::shuffled(n as usize, place.div_euclid(n))[index] } else { index };
        self.entries[i].clone()
    }

    /// This schedule as it should run when it replaces `old` at `now`. A rotation that was
    /// already running keeps its current entry and goes on from there; one that wasn't starts at
    /// the top.
    pub fn continued(&self, old: &WallpaperSchedule, now: f64) -> WallpaperSchedule {
        if !self.enabled || self.mode != Mode::Rotate || self.entries.is_empty() {
            return self.clone();
        }
        let mut s = self.clone();
        // whole seconds, so counting steps back from here can't round into the step before
        let seconds = now.floor();
        let n = self.entries.len() as i64;
        if !old.enabled || old.mode != Mode::Rotate || old.entries.is_empty() {
            s.anchor = seconds;
            // the time picks the shuffled round (or which of two goes first), so starts differ
            s.shift = seconds as i64 * if self.shuffle && n == 2 { 1 } else { n };
            s.removed = None;
            return s;
        }
        let step = old.step(now);
        if self.interval() != old.interval() {
            // a full interval from now: counted from the last switch, the next could be overdue
            s.anchor = seconds - step as f64 * self.interval();
        }
        let ids = |e: &[ScheduleEntry]| e.iter().map(|x| x.id.clone()).collect::<Vec<_>>();
        if self.shuffle == old.shuffle && ids(&self.entries) == ids(&old.entries) {
            return s;
        }
        // Line up the current entry with this step or, if it's gone, the first one left of those
        // that were to follow with the next step. Two rounds reach them all when shuffled.
        let current = old.rotation_slot(now).entry;
        let index = self.entries.iter().position(|e| e.id == current.id);
        s.removed = if index.is_none() { Some(Removed { entry: current, step }) } else { None };
        let following = (step + 1..=step + 2 * old.entries.len() as i64)
            .find_map(|i| {
                let id = old.entry_at_step(i).id;
                self.entries.iter().position(|e| e.id == id)
            });
        let first = index.or(following).unwrap_or(0);
        let place = if self.shuffle && n > 2 {
            // every round of two starts with the same one; with more, a round that starts with it,
            // so every other entry shows before any repeats
            let mut round = seconds as i64;
            while Self::shuffled(n as usize, round)[0] != first {
                round += 1;
            }
            round * n
        } else {
            first as i64
        };
        s.shift = place - if index.is_none() { step + 1 } else { step };
        s
    }

    /// A fixed shuffle per round, seeded by the round number. A round never starts with the entry
    /// the round before ended on, so the same look doesn't show twice in a row. Two entries can
    /// only alternate, so all their rounds are the same; with more, the swap leaves the last entry
    /// alone, so the round before needn't be swapped to compare with it.
    pub fn shuffled(n: usize, round: i64) -> Vec<usize> {
        if n <= 2 {
            return (0..n).collect();
        }
        let order = |r: i64| {
            let mut rng = SplitMix((r as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1));
            let mut a: Vec<usize> = (0..n).collect();
            for i in (1..n).rev() {
                let j = (rng.next() % (i as u64 + 1)) as usize;
                a.swap(i, j);
            }
            a
        };
        let mut a = order(round);
        if a.first() == order(round - 1).last() {
            a.swap(0, 1);
        }
        a
    }

    /// The latest start at or before `date` across the past week, and the first one after it.
    fn timed_slot(&self, date: f64, cal: &dyn LocalCalendar) -> Option<Slot> {
        let mut best: Option<(f64, &ScheduleEntry)> = None;
        let mut next: Option<f64> = None;
        let today = cal.local_day(date);
        for day in today - 7..=today + 7 {
            let weekday = weekday(day);
            for entry in self.entries.iter().filter(|e| e.weekdays.contains(&weekday)) {
                let Some(start) = cal.start(day, entry.minute) else { continue };
                if start <= date {
                    // later entries win a tie, like the last line of a list
                    if best.is_none_or(|(b, _)| start >= b) {
                        best = Some((start, entry));
                    }
                } else if next.is_none_or(|n| start < n) {
                    next = Some(start);
                }
            }
        }
        let (start, entry) = best?;
        Some(Slot {
            key: format!("timed {} {} {:?}", (start + REFERENCE_UNIX) as i64, entry.id, entry.target),
            entry: entry.clone(),
            next,
        })
    }

    /// Rotation only: this schedule moved on to the next entry now, with the interval starting
    /// over from here.
    pub fn skipped(&self, now: f64, cal: &dyn LocalCalendar) -> Option<WallpaperSchedule> {
        if self.mode != Mode::Rotate {
            return None;
        }
        let next = self.slot(now, cal)?.next?;
        let mut s = self.clone();
        s.anchor -= next - now;
        Some(s)
    }
}

/// 1 = Sunday ... 7 = Saturday for a day counted from 1970-01-01, which was a Thursday.
pub fn weekday(day: i64) -> i64 {
    (day + 4).rem_euclid(7) + 1
}

/// Local dates and times, for timed entries. The system one follows Windows' time zone, with its
/// daylight saving rules; tests use a fixed offset.
pub trait LocalCalendar {
    /// The local calendar day `t` falls on, counted from 1970-01-01.
    fn local_day(&self, t: f64) -> i64;
    /// When `minute` after midnight on local `day` is, or None if that day has no such time.
    fn start(&self, day: i64, minute: i64) -> Option<f64>;
    /// `t` as the status line shows it: the time alone today, else with the day.
    fn describe(&self, t: f64, now: f64) -> String;
}

/// Days from 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// A fixed offset from UTC, in seconds east.
pub struct FixedOffset(pub f64);

impl LocalCalendar for FixedOffset {
    fn local_day(&self, t: f64) -> i64 {
        ((t + REFERENCE_UNIX + self.0) / 86_400.0).floor() as i64
    }
    fn start(&self, day: i64, minute: i64) -> Option<f64> {
        Some(day as f64 * 86_400.0 + minute as f64 * 60.0 - self.0 - REFERENCE_UNIX)
    }
    fn describe(&self, t: f64, now: f64) -> String {
        let local = t + REFERENCE_UNIX + self.0;
        let minute = (local.rem_euclid(86_400.0) / 60.0).floor() as i64;
        let time = format!("{}:{:02}", minute / 60, minute % 60);
        match self.local_day(t) - self.local_day(now) {
            0 => time,
            1 => format!("Tomorrow, {time}"),
            _ => {
                let (y, m, d) = civil_from_days(self.local_day(t));
                format!("{y}-{m:02}-{d:02}, {time}")
            }
        }
    }
}

/// Windows' own time zone, and the user's own time and date formats.
pub struct SystemCalendar;

mod win {
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{FILETIME, SYSTEMTIME};
    use windows::Win32::Globalization::{GetDateFormatEx, GetTimeFormatEx, DATE_SHORTDATE, TIME_NOSECONDS};
    use windows::Win32::System::Time::{
        FileTimeToSystemTime, SystemTimeToFileTime, SystemTimeToTzSpecificLocalTime, TzSpecificLocalTimeToSystemTime,
    };

    use super::REFERENCE_UNIX;

    /// FILETIME counts 100 ns ticks from 1601.
    const TICKS_TO_UNIX: f64 = 11_644_473_600.0;

    pub fn local(t: f64) -> Option<SYSTEMTIME> {
        let ticks = ((t + REFERENCE_UNIX + TICKS_TO_UNIX) * 1e7) as u64;
        let ft = FILETIME { dwLowDateTime: ticks as u32, dwHighDateTime: (ticks >> 32) as u32 };
        let (mut utc, mut local) = (SYSTEMTIME::default(), SYSTEMTIME::default());
        unsafe {
            FileTimeToSystemTime(&ft, &mut utc).ok()?;
            SystemTimeToTzSpecificLocalTime(None, &utc, &mut local).ok()?;
        }
        Some(local)
    }

    pub fn from_local(local: &SYSTEMTIME) -> Option<f64> {
        let (mut utc, mut ft) = (SYSTEMTIME::default(), FILETIME::default());
        unsafe {
            TzSpecificLocalTimeToSystemTime(None, local, &mut utc).ok()?;
            SystemTimeToFileTime(&utc, &mut ft).ok()?;
        }
        let ticks = ((ft.dwHighDateTime as u64) << 32) | ft.dwLowDateTime as u64;
        Some(ticks as f64 / 1e7 - TICKS_TO_UNIX - REFERENCE_UNIX)
    }

    fn text(buf: &[u16], n: i32) -> String {
        String::from_utf16_lossy(&buf[..(n.max(1) - 1) as usize])
    }

    pub fn time(st: &SYSTEMTIME) -> String {
        let mut buf = [0u16; 64];
        let n = unsafe { GetTimeFormatEx(PCWSTR::null(), TIME_NOSECONDS, Some(st), PCWSTR::null(), Some(&mut buf)) };
        text(&buf, n)
    }

    pub fn date(st: &SYSTEMTIME) -> String {
        let mut buf = [0u16; 64];
        let n = unsafe { GetDateFormatEx(PCWSTR::null(), DATE_SHORTDATE, Some(st), PCWSTR::null(), Some(&mut buf), PCWSTR::null()) };
        text(&buf, n)
    }
}

impl LocalCalendar for SystemCalendar {
    fn local_day(&self, t: f64) -> i64 {
        match win::local(t) {
            Some(st) => days_from_civil(st.wYear as i64, st.wMonth as i64, st.wDay as i64),
            None => FixedOffset(0.0).local_day(t),
        }
    }

    fn start(&self, day: i64, minute: i64) -> Option<f64> {
        let (y, m, d) = civil_from_days(day);
        let st = windows::Win32::Foundation::SYSTEMTIME {
            wYear: y as u16, wMonth: m as u16, wDay: d as u16, wHour: (minute / 60) as u16,
            wMinute: (minute % 60) as u16, ..Default::default()
        };
        win::from_local(&st)
    }

    fn describe(&self, t: f64, now: f64) -> String {
        let Some(st) = win::local(t) else { return FixedOffset(0.0).describe(t, now) };
        let time = win::time(&st);
        match self.local_day(t) - self.local_day(now) {
            0 => time,
            1 => format!("Tomorrow, {time}"),
            _ => format!("{}, {time}", win::date(&st)),
        }
    }
}


/// `minute` after midnight in the user's own time format ("9:05 AM", "09:05").
pub fn time_of_day(minute: i64) -> String {
    let st = windows::Win32::Foundation::SYSTEMTIME {
        wYear: 2001, wMonth: 1, wDay: 1, wHour: (minute / 60) as u16, wMinute: (minute % 60) as u16, ..Default::default()
    };
    let t = win::time(&st);
    if t.is_empty() { format!("{}:{:02}", minute / 60, minute % 60) } else { t }
}

// MARK: the last switch

/// What the wallpaper last switched to: the slot's key, and the look that switch left on screen
/// (for telling a change made by hand since).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduleState {
    pub last_slot: Option<String>,
    pub last_look: Option<LastLook>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LastLook {
    pub slot: String,
    pub config: WallpaperConfig,
}

impl ScheduleState {
    pub fn path() -> PathBuf {
        dir().join("schedule-state.json")
    }

    pub fn load_from(path: &Path) -> ScheduleState {
        let Ok(text) = std::fs::read_to_string(path) else { return ScheduleState::default() };
        let Ok(Value::Object(d)) = serde_json::from_str::<Value>(&text) else { return ScheduleState::default() };
        let last_slot = d.get("lastSlot").and_then(Value::as_str).map(str::to_string);
        // the look through the config's lenient decoder, so one saved by another version reads
        let last_look = d.get("lastLook").and_then(Value::as_object).and_then(|l| {
            Some(LastLook {
                slot: l.get("slot")?.as_str()?.to_string(),
                config: WallpaperConfig::decode(&l.get("config")?.to_string())?,
            })
        });
        ScheduleState { last_slot, last_look }
    }

    pub fn save_to(&self, path: &Path) {
        let _ = std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")));
        if let Ok(text) = serde_json::to_string_pretty(self) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, path);
            }
        }
    }

    /// The look left by the last switch, if it was this slot's (an older one is never compared).
    pub fn look_for(&self, slot: &str) -> Option<&WallpaperConfig> {
        self.last_look.as_ref().filter(|l| Some(&l.slot) == self.last_slot.as_ref() && l.slot == slot).map(|l| &l.config)
    }
}

/// A switch the schedule wants made now.
#[derive(Clone, Debug, PartialEq)]
pub struct Switch {
    pub config: WallpaperConfig,
    /// 0 cuts straight over
    pub seconds: f64,
    /// never Random; that's resolved here
    pub style: TransitionStyle,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Evaluation {
    pub switch: Option<Switch>,
    /// When to look again: just after the next switch is due.
    pub next: Option<f64>,
}

/// Works out which entry is due and whether to switch to it (Scheduler.evaluate). Each switch
/// happens once, when its slot begins, so changes made by hand in between stay until the next
/// one. `fade` is false for the first look at launch, since nothing is on screen yet.
pub fn evaluate(s: &WallpaperSchedule, now: f64, config: &WallpaperConfig, presets: &[UserPreset],
                state: &mut ScheduleState, fade: bool, cal: &dyn LocalCalendar) -> Evaluation {
    let none = Evaluation { switch: None, next: None };
    if !s.enabled {
        return none;
    }
    let Some(slot) = s.slot(now, cal) else { return none };
    let next = slot.next.map(|n| n + 0.2);
    // an entry removed before it could show isn't switched to
    if state.last_slot.as_ref() == Some(&slot.key) || !s.entries.iter().any(|e| e.id == slot.entry.id) {
        return Evaluation { switch: None, next };
    }
    // a deleted preset leaves the wallpaper as it is
    let new = slot.entry.target.applied(config, presets);
    let after = new.clone().unwrap_or_else(|| config.clone());
    let switch = new.filter(|n| n != config).map(|n| Switch {
        config: n,
        seconds: if fade { s.fade_seconds } else { 0.0 },
        style: s.transition.resolved(),
    });
    state.last_slot = Some(slot.key.clone());
    // kept with its slot, so an old one is never compared after a later switch
    state.last_look = Some(LastLook { slot: slot.key, config: after });
    Evaluation { switch, next }
}

/// The Schedule section's line on what's showing and what comes next (ScheduleStatus.swift).
pub fn status(s: &WallpaperSchedule, config: &WallpaperConfig, presets: &[UserPreset], state: &ScheduleState,
              now: f64, cal: &dyn LocalCalendar) -> String {
    if !s.enabled {
        return "Off. Your wallpaper stays as you set it.".into();
    }
    let Some(slot) = s.slot(now, cal) else {
        return if s.entries.is_empty() { "Nothing to show yet." } else { "Nothing has started yet." }.into();
    };
    let mut text = showing(s, &slot, config, presets, state);
    if let Some(next) = slot.next {
        text += &format!(" Next switch {}.", cal.describe(next, now));
    }
    text
}

fn showing(s: &WallpaperSchedule, slot: &Slot, config: &WallpaperConfig, presets: &[UserPreset], state: &ScheduleState) -> String {
    let removed = !s.entries.iter().any(|e| e.id == slot.entry.id);
    let last = state.last_slot.as_ref() == Some(&slot.key);
    if removed && !last {
        return "The scheduled look was removed before it could show.".into();
    }
    if last && changed_by_hand(&slot.entry.target, config, presets, state.look_for(&slot.key)) {
        return "Changed by hand since the last switch.".into();
    }
    if let ScheduleTarget::Preset { id } = &slot.entry.target {
        if !presets.iter().any(|p| &p.id == id) {
            return "The scheduled preset was deleted, so the wallpaper stays as it is.".into();
        }
    }
    format!("Now: {}{}.", slot.entry.target.title(presets), if removed { " (removed from the schedule)" } else { "" })
}

/// Compared with the look right after the switch: what the entry would apply now is no guide,
/// since a scene keeps any settings and a preset can be edited. A preset saved over with the
/// current look is showing, though, so that isn't a change.
fn changed_by_hand(target: &ScheduleTarget, config: &WallpaperConfig, presets: &[UserPreset],
                   last_look: Option<&WallpaperConfig>) -> bool {
    let Some(last_look) = last_look else { return false };
    let look = visible_settings(config);
    if look == visible_settings(last_look) {
        return false;
    }
    match (target, target.applied(config, presets)) {
        (ScheduleTarget::Preset { .. }, Some(now)) => look != visible_settings(&now),
        _ => true,
    }
}

// MARK: the saved schedule

/// schedule.json, re-read when another program changes it.
pub struct ScheduleStore {
    pub schedule: WallpaperSchedule,
    path: PathBuf,
    modified: Option<SystemTime>,
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

impl ScheduleStore {
    pub fn load() -> ScheduleStore {
        Self::at(dir().join("schedule.json"))
    }

    pub fn at(path: PathBuf) -> ScheduleStore {
        let modified = mtime(&path);
        let schedule = std::fs::read_to_string(&path).ok().and_then(|t| WallpaperSchedule::decode(&t)).unwrap_or_default();
        ScheduleStore { schedule, path, modified }
    }

    /// The schedule before the change, when another program changed it.
    pub fn reload_if_changed(&mut self) -> Option<WallpaperSchedule> {
        let m = mtime(&self.path);
        if m == self.modified {
            return None;
        }
        self.modified = m;
        let new = std::fs::read_to_string(&self.path).ok().and_then(|t| WallpaperSchedule::decode(&t))?;
        if new == self.schedule {
            return None;
        }
        Some(std::mem::replace(&mut self.schedule, new))
    }

    /// Stores an edit, continued from the schedule it replaces (so a running rotation keeps its
    /// place). The schedule before, if anything changed.
    pub fn set(&mut self, new: WallpaperSchedule) -> Option<WallpaperSchedule> {
        let new = new.continued(&self.schedule, now());
        if new == self.schedule {
            return None;
        }
        let old = std::mem::replace(&mut self.schedule, new);
        let _ = std::fs::create_dir_all(self.path.parent().unwrap_or(Path::new(".")));
        if let Ok(text) = serde_json::to_string_pretty(&self.schedule) {
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
        self.modified = mtime(&self.path);
        Some(old)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entries(n: usize) -> Vec<ScheduleEntry> {
        SceneKind::listed().into_iter().take(n).map(|k| ScheduleEntry::new(ScheduleTarget::Scene { kind: k })).collect()
    }

    fn rotating(n: usize, shuffle: bool) -> WallpaperSchedule {
        WallpaperSchedule { enabled: true, entries: entries(n), shuffle, anchor: 0.0, ..Default::default() }
    }

    #[test]
    fn dates_round_trip() {
        for day in [-800_000, -1, 0, 59, 10_957, 20_783, 2_000_000] {
            let (y, m, d) = civil_from_days(day);
            assert_eq!(days_from_civil(y, m, d), day);
        }
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(weekday(0), 5); // a Thursday
        assert_eq!(weekday(days_from_civil(2026, 11, 26)), 5);
    }

    #[test]
    fn json_matches_the_mac() {
        let mut s = rotating(2, false);
        s.entries[1].target = ScheduleTarget::Preset { id: "ABC".into() };
        let text = serde_json::to_string(&s).unwrap();
        assert!(text.contains(r#""target":{"scene":{"_0":"blackHole"}}"#), "{text}");
        assert!(text.contains(r#""target":{"preset":{"_0":"ABC"}}"#));
        assert!(text.contains(r#""intervalMinutes":60.0"#) && text.contains(r#""transition":"dissolve""#));
        assert_eq!(WallpaperSchedule::decode(&text).unwrap(), s);
        // a bad key keeps its default alone
        let s = WallpaperSchedule::decode(r#"{"enabled":true,"mode":"sideways","fadeSeconds":4}"#).unwrap();
        assert!(s.enabled && s.mode == Mode::Rotate && s.fade_seconds == 4.0);
    }

    #[test]
    fn rotation_steps_and_shuffles_without_repeats() {
        let s = rotating(3, false);
        let ids: Vec<String> = (0..4).map(|i| s.slot(i as f64 * 3600.0 + 1.0, &FixedOffset(0.0)).unwrap().entry.id).collect();
        assert_eq!(ids[0], s.entries[0].id);
        assert_eq!(ids[1], s.entries[1].id);
        assert_eq!(ids[3], s.entries[0].id);
        for n in 3..7 {
            for round in -5..40 {
                let a = WallpaperSchedule::shuffled(n, round);
                let mut sorted = a.clone();
                sorted.sort();
                assert_eq!(sorted, (0..n).collect::<Vec<_>>());
                assert_ne!(a.first(), WallpaperSchedule::shuffled(n, round - 1).last(), "a look twice in a row");
            }
        }
    }

    #[test]
    fn edits_keep_the_current_entry() {
        let cal = FixedOffset(0.0);
        let now = 3.5 * 3600.0;
        let old = rotating(4, false);
        let showing = old.slot(now, &cal).unwrap().entry;
        // adding one, or shuffling, keeps what shows
        let mut new = old.clone();
        new.entries.push(ScheduleEntry::new(ScheduleTarget::Scene { kind: SceneKind::Comet }));
        assert_eq!(new.continued(&old, now).slot(now, &cal).unwrap().entry.id, showing.id);
        let mut new = old.clone();
        new.shuffle = true;
        assert_eq!(new.continued(&old, now).slot(now, &cal).unwrap().entry.id, showing.id);
        // removing it keeps it until its step ends, then goes on with the one that was next
        let next_up = old.slot(now + 3600.0, &cal).unwrap().entry;
        let mut new = old.clone();
        new.entries.retain(|e| e.id != showing.id);
        let c = new.continued(&old, now);
        assert_eq!(c.slot(now, &cal).unwrap().entry.id, showing.id);
        assert_eq!(c.slot(now + 3600.0, &cal).unwrap().entry.id, next_up.id);
        // turning it on starts at the top of a fresh interval
        let mut off = old.clone();
        off.enabled = false;
        let c = old.continued(&off, now);
        assert_eq!(c.anchor, now.floor());
        // skipping moves on now
        let skipped = old.skipped(now, &cal).unwrap();
        assert_eq!(skipped.slot(now, &cal).unwrap().entry.id, next_up.id);
    }

    #[test]
    fn timed_entries_hold_until_the_next() {
        let cal = FixedOffset(-5.0 * 3600.0);
        let mut s = WallpaperSchedule { enabled: true, mode: Mode::Timed, entries: entries(2), ..Default::default() };
        s.entries[0].minute = 8 * 60;
        s.entries[1].minute = 20 * 60;
        let day = days_from_civil(2026, 11, 26);
        let at = |h: i64, m: i64| cal.start(day, h * 60 + m).unwrap();
        assert_eq!(s.slot(at(12, 0), &cal).unwrap().entry.id, s.entries[0].id);
        assert_eq!(s.slot(at(12, 0), &cal).unwrap().next, Some(at(20, 0)));
        // overnight, the evening one holds
        assert_eq!(s.slot(at(3, 0), &cal).unwrap().entry.id, s.entries[1].id);
        // only on its weekdays: Thursday off, so Wednesday's evening start holds into Thursday
        s.entries[0].weekdays = [1, 2, 3, 4, 6, 7].into_iter().collect();
        assert_eq!(s.slot(at(12, 0), &cal).unwrap().entry.id, s.entries[1].id);
        assert_eq!(cal.describe(at(20, 0), at(12, 0)), "20:00");
        assert_eq!(cal.describe(at(20, 0) + 86_400.0, at(12, 0)), "Tomorrow, 20:00");
    }

    #[test]
    fn switches_once_per_slot_and_notices_hand_changes() {
        let cal = FixedOffset(0.0);
        let s = rotating(2, false);
        let mut state = ScheduleState::default();
        let c = WallpaperConfig::default();
        let e = evaluate(&s, 3601.0, &c, &[], &mut state, true, &cal);
        let sw = e.switch.unwrap();
        assert_eq!((sw.config.scene, sw.seconds, sw.style), (s.entries[1].target_scene(), 8.0, TransitionStyle::Dissolve));
        assert_eq!(e.next, Some(7200.2));
        // the same slot again: nothing, even after a change by hand
        let mut by_hand = sw.config.clone();
        assert!(evaluate(&s, 3700.0, &by_hand, &[], &mut state, true, &cal).switch.is_none());
        assert!(status(&s, &by_hand, &[], &state, 3700.0, &cal).starts_with("Now: "));
        by_hand.disk_speed = 2.0;
        by_hand.set_scene(SceneKind::Comet);
        assert!(status(&s, &by_hand, &[], &state, 3700.0, &cal).starts_with("Changed by hand"));
        // a deleted preset leaves the look alone
        let mut p = rotating(1, false);
        p.entries[0].target = ScheduleTarget::Preset { id: "gone".into() };
        let mut state = ScheduleState::default();
        assert!(evaluate(&p, 10.0, &c, &[], &mut state, true, &cal).switch.is_none());
        assert!(status(&p, &c, &[], &state, 10.0, &cal).starts_with("The scheduled preset was deleted"));
    }

    impl ScheduleEntry {
        fn target_scene(&self) -> SceneKind {
            match self.target {
                ScheduleTarget::Scene { kind } => kind,
                _ => panic!(),
            }
        }
    }

    /// The rotation half of the Mac's ScheduleCheck.swift, case for case.
    #[test]
    fn schedule_check_rotation() {
        let cal = FixedOffset(-5.0 * 3600.0);
        let date = |y, m, d, h: i64, min: i64| cal.start(days_from_civil(y, m, d), h * 60 + min).unwrap();
        let entry = |k| ScheduleEntry::new(ScheduleTarget::Scene { kind: k });
        let (a, b, c) = (entry(SceneKind::Galaxy), entry(SceneKind::Comet), entry(SceneKind::Pulsar));
        let mut failures: Vec<String> = Vec::new();
        let mut expect = |ok: bool, what: &str| {
            if !ok {
                failures.push(what.to_string());
            }
        };

        let mut r = WallpaperSchedule { entries: vec![a.clone(), b.clone(), c.clone()], interval_minutes: 30.0, ..Default::default() };
        r.anchor = date(2026, 11, 16, 9, 0);
        let slot = |s: &WallpaperSchedule, t: f64| s.slot(t, &cal);
        let picks: Vec<String> = (0..6).map(|i| slot(&r, r.anchor + i as f64 * 1800.0 + 60.0).unwrap().entry.id).collect();
        expect(picks == [&a.id, &b.id, &c.id, &a.id, &b.id, &c.id].map(|s| s.clone()), "rotation order");
        let (s0, s1) = (slot(&r, r.anchor + 60.0).unwrap(), slot(&r, r.anchor + 1700.0).unwrap());
        expect(s0.key == s1.key, "rotation key changed within a step");
        expect(s0.next == Some(r.anchor + 1800.0), "rotation next switch");

        // saved rotations of three or more depend on these orders, so they can't change
        for (round, order) in [(-1i64, vec![2usize, 0, 1]), (2, vec![2, 1, 0]), (-7, vec![1, 3, 2, 4, 0]),
                               (800_000_000, vec![3, 0, 1, 4, 2]), (817_000_000, vec![9, 1, 4, 6, 2, 8, 11, 10, 3, 7, 0, 5])] {
            expect(WallpaperSchedule::shuffled(order.len(), round) == order, &format!("shuffle of {}, round {round} changed", order.len()));
        }
        for n in 1..=12 {
            for round in (-60..=60).chain([-800_000_000i64, 800_000_000, 1_000_000_000_000].into_iter().flat_map(|b| b..=b + 60)) {
                let o = WallpaperSchedule::shuffled(n, round);
                let mut s = o.clone();
                s.sort();
                expect(s == (0..n).collect::<Vec<_>>(), "shuffle isn't a permutation");
                expect(n == 1 || o.first() != WallpaperSchedule::shuffled(n, round - 1).last(), "shuffle repeats");
            }
        }

        // editing a running rotation keeps the current slot and goes on from it
        r.enabled = true;
        let now = r.anchor + 4.0 * 1800.0 + 1201.3;
        let before = slot(&r, now).unwrap();
        let edited = |s: &WallpaperSchedule, f: &dyn Fn(&mut WallpaperSchedule)| {
            let mut new = s.clone();
            f(&mut new);
            new.continued(s, now)
        };
        let upcoming = |s: &WallpaperSchedule, count: usize| -> Vec<String> {
            let first = slot(s, now).unwrap().next.unwrap();
            (0..count).map(|i| slot(s, first + (i as f64 + 0.5) * s.interval_minutes * 60.0).unwrap().entry.id).collect()
        };
        let ids = |v: &[&ScheduleEntry]| v.iter().map(|e| e.id.clone()).collect::<Vec<_>>();
        let set = |v: Vec<String>| v.into_iter().collect::<BTreeSet<_>>();
        let d = entry(SceneKind::Eclipse);
        let added = edited(&r, &|s| s.entries.insert(0, d.clone()));
        expect(slot(&added, now) == Some(before.clone()), "adding an entry changed the slot");
        expect(upcoming(&added, 4) == ids(&[&c, &d, &a, &b]), "order after adding");
        let cut = edited(&r, &|s| { s.entries.remove(0); });
        expect(slot(&cut, now) == Some(before.clone()), "removing another entry changed the slot");
        expect(upcoming(&cut, 2) == ids(&[&c, &b]), "order after removing another entry");
        let moved = edited(&r, &|s| s.entries.swap(1, 0));
        expect(slot(&moved, now) == Some(before.clone()), "reordering changed the slot");
        expect(upcoming(&moved, 3) == ids(&[&a, &c, &b]), "order after reordering");

        let mut held = edited(&r, &|s| { s.entries.remove(1); });
        expect(slot(&held, now) == Some(before.clone()), "removing the current entry changed the slot");
        expect(upcoming(&held, 3) == ids(&[&c, &a, &c]), "order after removing the current entry");
        held = edited(&held, &|s| s.entries = vec![d.clone(), c.clone(), a.clone()]);
        expect(slot(&held, now) == Some(before.clone()), "reordering after removing the current entry changed the slot");
        expect(upcoming(&held, 3) == ids(&[&c, &a, &d]), "order after removing the current entry and reordering");
        for i in 0..held.entries.len() {
            let e = edited(&held, &|s| s.entries[i].target = ScheduleTarget::Scene { kind: SceneKind::BlackHole });
            expect(slot(&e, now) == Some(before.clone()), "changing another entry's target after removing the current one");
        }
        held = edited(&held, &|s| { s.entries.remove(1); });
        expect(slot(&held, now) == Some(before.clone()), "removing the next entry too changed the slot");
        expect(upcoming(&held, 2) == ids(&[&a, &d]), "order after removing the next entry too");
        let replaced = edited(&r, &|s| s.entries = vec![d.clone()]);
        expect(slot(&replaced, now) == Some(before.clone()) && upcoming(&replaced, 1) == ids(&[&d]), "replacing every entry");

        let target = slot(&edited(&r, &|s| s.entries[1].target = ScheduleTarget::Scene { kind: SceneKind::Eclipse }), now).unwrap();
        expect(target.key != before.key && target.entry.id == b.id && target.next == before.next, "changing the current target");

        for minutes in INTERVALS.into_iter().filter(|&m| m != 30.0) {
            let s = edited(&r, &|s| s.interval_minutes = minutes);
            let sl = slot(&s, now).unwrap();
            expect(sl.key == before.key && upcoming(&s, 2) == ids(&[&c, &a]), &format!("interval {minutes} changed the slot"));
            expect((sl.next.unwrap() - now - minutes * 60.0).abs() <= 1.0, &format!("interval {minutes} next switch"));
            let h = edited(&edited(&r, &|s| { s.entries.remove(1); }), &|s| s.interval_minutes = minutes);
            expect(slot(&h, now).map(|x| x.key) == Some(before.key.clone()) && upcoming(&h, 2) == ids(&[&c, &a]),
                   &format!("interval {minutes} after removing the current entry"));
        }

        let mixed = edited(&r, &|s| s.shuffle = true);
        expect(slot(&mixed, now) == Some(before.clone()), "turning shuffle on changed the slot");
        expect(set(upcoming(&mixed, 2)) == set(ids(&[&a, &c])), "round after turning shuffle on");
        let grown = edited(&mixed, &|s| s.entries.insert(0, d.clone()));
        expect(slot(&grown, now) == Some(before.clone()), "adding while shuffled changed the slot");
        expect(set(upcoming(&grown, 3)) == set(ids(&[&a, &c, &d])), "round after adding while shuffled");
        let reversed = edited(&grown, &|s| s.entries.reverse());
        expect(slot(&reversed, now) == Some(before.clone()), "reordering while shuffled changed the slot");
        let next = upcoming(&grown, 1);
        let shrunk = edited(&grown, &|s| s.entries.retain(|e| e.id != b.id));
        expect(slot(&shrunk, now) == Some(before.clone()) && upcoming(&shrunk, 1) == next, "removing the current entry while shuffled");
        expect(set(upcoming(&shrunk, 3)) == set(ids(&[&a, &c, &d])), "round after removing the current entry while shuffled");
        let pair = edited(&mixed, &|s| { s.entries.remove(0); });
        expect(slot(&pair, now) == Some(before.clone()) && upcoming(&pair, 1) == ids(&[&c]), "two entries left while shuffled");
        let sorted = edited(&grown, &|s| s.shuffle = false);
        expect(slot(&sorted, now) == Some(before.clone()) && upcoming(&sorted, 2) == ids(&[&c, &d]), "turning shuffle off");

        // two shuffled entries alternate from whichever is current, however they came to be two
        for (current, other) in [(&a, &b), (&b, &a)] {
            let alternates = |s: &WallpaperSchedule, what: &str, expect: &mut dyn FnMut(bool, &str)| {
                expect(slot(s, now).map(|x| x.entry.id) == Some(current.id.clone()), &format!("{what}: the current entry changed"));
                let want: Vec<String> = (0..40).map(|i| if i % 2 == 0 { other.id.clone() } else { current.id.clone() }).collect();
                expect(upcoming(s, 40) == want, &format!("{what}: doesn't alternate"));
            };
            let mut two = r.clone();
            two.entries = vec![a.clone(), b.clone()];
            two.shift = if current.id == a.id { 0 } else { 1 };
            let on = edited(&two, &|s| s.shuffle = true);
            alternates(&on, "shuffling two", &mut expect);
            alternates(&edited(&on, &|s| s.entries.reverse()), "reordering two shuffled", &mut expect);
            alternates(&edited(&on, &|s| s.interval_minutes = 5.0), "a new interval for two shuffled", &mut expect);
            alternates(&edited(&edited(&on, &|s| s.shuffle = false), &|s| s.shuffle = true), "shuffling two again", &mut expect);
            let three = edited(&on, &|s| s.entries.insert(1, c.clone()));
            alternates(&edited(&three, &|s| { s.entries.remove(1); }), "down to two shuffled", &mut expect);
            let one = edited(&on, &|s| s.entries = vec![current.clone()]);
            expect(slot(&one, now) == slot(&on, now) && upcoming(&one, 2) == ids(&[current, current]), "down to one shuffled");
            alternates(&edited(&one, &|s| s.entries = vec![a.clone(), b.clone()]), "back to two shuffled", &mut expect);
            let gone = edited(&three, &|s| s.entries = vec![c.clone(), other.clone()]);
            let after = upcoming(&gone, 40);
            expect(slot(&gone, now) == slot(&three, now) && after.first() == upcoming(&three, 1).first()
                   && after.windows(2).all(|w| w[0] != w[1]), "removing the current entry, down to two shuffled");
            let last = edited(&on, &|s| s.entries = vec![other.clone()]);
            expect(slot(&last, now) == slot(&on, now) && upcoming(&last, 2) == ids(&[other, other]),
                   "removing the current entry, down to one shuffled");
        }
        let mut started = BTreeSet::new();
        for second in 0..2 {
            let on = now + second as f64;
            let off = WallpaperSchedule { entries: vec![a.clone(), b.clone()], shuffle: true, ..Default::default() };
            let mut s = off.clone();
            s.enabled = true;
            s = s.continued(&off, on);
            let shown: Vec<String> = (0..40).map(|i| slot(&s, on + i as f64 * 3600.0).unwrap().entry.id).collect();
            started.insert(shown[0].clone());
            expect(shown.windows(2).all(|w| w[0] != w[1]), "turning on two shuffled: doesn't alternate");
        }
        expect(started == set(ids(&[&a, &b])), "turning on two shuffled always starts with the same one");

        let unrelated: [&dyn Fn(&mut WallpaperSchedule); 5] = [
            &|s| s.anchor -= 1200.0, &|s| s.fade_seconds = 2.0, &|s| { s.enabled = false; s.entries.remove(0); },
            &|s| { s.mode = Mode::Timed; s.entries.remove(0); }, &|s| s.entries.clear()];
        for edit in unrelated {
            let mut s = grown.clone();
            edit(&mut s);
            expect(s.continued(&grown, now) == s, "an unrelated edit moved the rotation");
        }
        let skipped = edited(&held, &|s| s.anchor -= before.next.unwrap() - now + 0.1);
        expect(slot(&skipped, now).map(|x| x.entry.id) == Some(a.id.clone()) && upcoming(&skipped, 1) == ids(&[&d]),
               "Next Now after removing the current entry");

        for s in [&r, &held, &grown, &shrunk] {
            expect(WallpaperSchedule::decode(&serde_json::to_string(s).unwrap()).as_ref() == Some(s), "saving and loading changed the schedule");
        }
        let older = WallpaperSchedule::decode(r#"{"enabled": true, "anchor": 0}"#).unwrap();
        expect(older.enabled && older.shift == 0 && older.removed.is_none() && older.anchor == 0.0, "an older save");

        let (mut off, mut times, mut empty) = (held.clone(), r.clone(), r.clone());
        off.enabled = false;
        off.removed = Some(Removed { entry: b.clone(), step: 0 });
        times.mode = Mode::Timed;
        empty.entries.clear();
        for (what, old) in [("turning on", &off), ("leaving set times", &times), ("the first entry", &empty)] {
            for shuffle in [false, true] {
                let s = edited(old, &|s| {
                    s.enabled = true;
                    s.mode = Mode::Rotate;
                    s.entries = vec![a.clone(), b.clone(), c.clone()];
                    s.shuffle = shuffle;
                });
                let sl = slot(&s, now).unwrap();
                expect((sl.next.unwrap() - now - 1800.0).abs() <= 1.0, &format!("{what}: not a full interval"));
                expect(shuffle || sl.entry.id == a.id, &format!("{what}: not the first entry"));
                let mut all = upcoming(&s, 2);
                all.push(sl.entry.id);
                expect(set(all) == set(ids(&[&a, &b, &c])), &format!("{what}: not a whole round"));
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
}
