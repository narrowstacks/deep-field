//! The live wallpaper: one borderless child window per monitor behind the desktop icons, each
//! rendering the scene at (screen pixels / pixelSize) and scaling it up with nearest-neighbor
//! filtering (after App/WallpaperWindow.swift and Rendering/WallpaperView.swift).
//!
//! Windows draws the desktop icons in a SHELLDLL_DefView window. Sending Progman the
//! undocumented 0x052C message makes Explorer split a WorkerW window off behind the icons; a
//! window parented to it shows between the wallpaper and the icons. On Windows 11 24H2 and
//! later that WorkerW is a child of Progman instead of a top-level window, and our window goes
//! into Progman just below the icon view.

use std::collections::HashMap;
use std::rc::Rc;
use std::time::{Duration, Instant};

use raw_window_handle::{RawDisplayHandle, RawWindowHandle, Win32WindowHandle, WindowsDisplayHandle};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows::Win32::System::Threading::INFINITE;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::config::WallpaperConfig;
use crate::config_store::ConfigStore;
use crate::events::EventSchedule;
use crate::renderer::{Baked, Renderer};
use crate::transition::TransitionStyle;
use crate::presets::PresetStore;
use crate::schedule::{self, ScheduleState, ScheduleStore, SystemCalendar, WallpaperSchedule};
use crate::tray::{Tray, TrayAction};

/// Where wallpaper windows go: the window to parent to, and (24H2+) the icon view to stay below.
struct DesktopHost {
    parent: HWND,
    below: Option<HWND>,
}

unsafe extern "system" fn find_worker(top: HWND, out: LPARAM) -> BOOL {
    // the WorkerW that matters is the one right after the top-level window holding the icons
    if let Ok(_view) = FindWindowExW(top, HWND::default(), w!("SHELLDLL_DefView"), PCWSTR::null()) {
        if let Ok(worker) = FindWindowExW(HWND::default(), top, w!("WorkerW"), PCWSTR::null()) {
            *(out.0 as *mut HWND) = worker;
        }
    }
    TRUE
}

fn find_desktop_host() -> Option<DesktopHost> {
    unsafe {
        let progman = FindWindowW(w!("Progman"), PCWSTR::null()).ok()?;
        // ask Explorer to create the WorkerW behind the icons (harmless if it already exists)
        let mut result = 0usize;
        SendMessageTimeoutW(progman, 0x052C, WPARAM(0xD), LPARAM(0x1), SMTO_NORMAL, 1000, Some(&mut result));
        // Windows 11 24H2+: the icon view and the WorkerW are both children of Progman
        if let Ok(view) = FindWindowExW(progman, HWND::default(), w!("SHELLDLL_DefView"), PCWSTR::null()) {
            if FindWindowExW(progman, HWND::default(), w!("WorkerW"), PCWSTR::null()).is_ok() {
                return Some(DesktopHost { parent: progman, below: Some(view) });
            }
        }
        let mut worker = HWND::default();
        let _ = EnumWindows(Some(find_worker), LPARAM(&mut worker as *mut HWND as isize));
        if !worker.is_invalid() {
            return Some(DesktopHost { parent: worker, below: None });
        }
        None
    }
}

unsafe extern "system" fn collect_monitor(m: HMONITOR, _: HDC, _: *mut RECT, out: LPARAM) -> BOOL {
    let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    if GetMonitorInfoW(m, &mut info).as_bool() {
        (*(out.0 as *mut Vec<RECT>)).push(info.rcMonitor);
    }
    TRUE
}

/// Each display's refresh rate in Hz (NSScreen.maximumFramesPerSecond on the Mac). Windows
/// reports 0 or 1 for a display left at its hardware default; those are left out.
pub fn display_rates() -> Vec<i64> {
    let mut rates = Vec::new();
    for i in 0.. {
        let mut dd = DISPLAY_DEVICEW { cb: std::mem::size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
        if !unsafe { EnumDisplayDevicesW(PCWSTR::null(), i, &mut dd, 0) }.as_bool() {
            break;
        }
        if dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP == 0 {
            continue;
        }
        let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
        if unsafe { EnumDisplaySettingsW(PCWSTR(dd.DeviceName.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm) }.as_bool()
            && dm.dmDisplayFrequency > 1
        {
            rates.push(dm.dmDisplayFrequency as i64);
        }
    }
    rates
}

/// The frame rates Customize offers (FrameRate.choices): the usual ones, each display's refresh
/// rate, and the saved rate whatever set it, so the picker always has it to show.
pub fn frame_rate_choices(displays: &[i64], current: i64) -> Vec<i64> {
    let mut v: Vec<i64> = crate::config::STANDARD_FPS.to_vec();
    v.extend(displays.iter().copied().filter(|r| (1..=crate::config::FPS_LIMIT).contains(r)));
    v.push(current);
    v.sort();
    v.dedup();
    v
}

/// Every monitor's rectangle in virtual-screen pixels.
fn monitors() -> Vec<RECT> {
    let mut rects: Vec<RECT> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(HDC::default(), None, Some(collect_monitor), LPARAM(&mut rects as *mut Vec<RECT> as isize));
    }
    rects
}

const WM_DEEPFIELD_REBUILD: u32 = WM_APP + 1;
/// Sent by `deepfield --quit` to a running copy.
const WM_DEEPFIELD_QUIT: u32 = WM_APP + 2;

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        // displays added, removed or rearranged: the windows are rebuilt from the main loop
        WM_DISPLAYCHANGE | WM_DPICHANGED => {
            let _ = PostMessageW(HWND::default(), WM_DEEPFIELD_REBUILD, WPARAM(0), LPARAM(0));
            LRESULT(0)
        }
        WM_DEEPFIELD_QUIT => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// A transition in progress on one screen (WallpaperView.Fade): the look being left, drawn from
/// its own bake and mixed with the new look by `Renderer::encode_transition`.
pub struct Fade {
    baked: Rc<Baked>,
    config: WallpaperConfig,
    /// `Renderer::elapsed` when it began
    start: f64,
    duration: f64,
    seed: f32,
    style: TransitionStyle,
    /// the two frames' targets, at the shaded size, made once per fade
    targets: Option<(wgpu::Texture, wgpu::Texture)>,
}

impl Fade {
    /// Eased progress, or None once it's over.
    fn progress(&self, now: f64) -> Option<f64> {
        let u = (now - self.start) / self.duration.max(0.001);
        if u >= 1.0 {
            return None;
        }
        let x = u.max(0.0);
        Some(x * x * (3.0 - 2.0 * x))
    }
}

/// One monitor's wallpaper: its window, swap chain, bake and frame target.
pub struct Screen {
    hwnd: HWND,
    surface: wgpu::Surface<'static>,
    format: wgpu::TextureFormat,
    size: (u32, u32),
    cells: Option<wgpu::Texture>,
    /// Shared with a fade while the outgoing look is drawn from it, so a re-bake then makes new
    /// textures instead of overwriting the ones the outgoing frame still reads.
    baked: Option<Rc<Baked>>,
    fade: Option<Fade>,
}

impl Screen {
    fn new(r: &Renderer, host: &DesktopHost, rect: RECT) -> Option<Screen> {
        unsafe {
            let instance = GetModuleHandleW(None).ok()?;
            // the host's client coordinates start at the virtual screen's top left
            let mut pts = [POINT { x: rect.left, y: rect.top }];
            MapWindowPoints(HWND::default(), host.parent, &mut pts);
            let (w, h) = ((rect.right - rect.left) as u32, (rect.bottom - rect.top) as u32);
            let hwnd = CreateWindowExW(
                WS_EX_NOACTIVATE,
                w!("DeepFieldWallpaper"),
                w!("Deep Field"),
                WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
                pts[0].x, pts[0].y, w as i32, h as i32,
                host.parent,
                HMENU::default(),
                instance,
                None,
            )
            .ok()?;
            if let Some(view) = host.below {
                // just below the icons, above Explorer's own wallpaper layer
                let _ = SetWindowPos(hwnd, view, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            }
            let mut handle = Win32WindowHandle::new(std::num::NonZeroIsize::new(hwnd.0 as isize)?);
            handle.hinstance = std::num::NonZeroIsize::new(instance.0 as isize);
            let surface = r
                .instance
                .create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                    raw_display_handle: RawDisplayHandle::Windows(WindowsDisplayHandle::new()),
                    raw_window_handle: RawWindowHandle::Win32(handle),
                })
                .ok()?;
            let caps = surface.get_capabilities(&r.adapter);
            // the frame is already gamma encoded by the shaders, so the swap chain must not encode again
            let format = caps.formats.iter().copied().find(|f| !f.is_srgb()).unwrap_or(caps.formats[0]);
            let present_mode = if caps.present_modes.contains(&wgpu::PresentMode::Mailbox) {
                wgpu::PresentMode::Mailbox
            } else {
                wgpu::PresentMode::Fifo
            };
            surface.configure(&r.device, &wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format,
                width: w.max(1),
                height: h.max(1),
                present_mode,
                desired_maximum_frame_latency: 2,
                alpha_mode: wgpu::CompositeAlphaMode::Auto,
                view_formats: vec![],
            });
            Some(Screen { hwnd, surface, format, size: (w, h), cells: None, baked: None, fade: None })
        }
    }

    fn draw(&mut self, r: &Renderer, store: &ConfigStore, events: &EventSchedule, elapsed: f64) {
        let c = &store.config;
        let px = c.pixel_size.max(1) as u32;
        let (cw, ch) = (self.size.0.div_ceil(px), self.size.1.div_ceil(px));
        if self.cells.as_ref().map(|t| (t.width(), t.height())) != Some((cw, ch)) {
            self.cells = Some(r.make_target(cw, ch, wgpu::TextureUsages::empty()));
            self.baked = None;
        }
        if let Some(f) = &mut self.fade {
            if (f.baked.width, f.baked.height) != (cw, ch) {
                // a different pixel size (or a resize) needs the outgoing look traced at the new size
                f.baked = Rc::new(r.bake(cw, ch, &f.config, None));
                f.targets = None;
            }
        }
        let stale = match &self.baked {
            Some(b) => !b.matches(c) || (b.width, b.height) != (cw, ch),
            None => true,
        };
        if stale {
            // while fading, the outgoing frame may still be drawing from the current textures, and
            // then the Rc is shared, so nothing is reused
            let old = self.baked.take().and_then(|b| Rc::try_unwrap(b).ok());
            self.baked = Some(Rc::new(r.bake(cw, ch, c, old)));
        }
        let frame = match self.surface.get_current_texture() {
            Ok(f) => f,
            Err(_) => return, // lost or outdated: skip this frame, the next reconfigure fixes it
        };
        let cells = self.cells.as_ref().unwrap();
        let baked = self.baked.as_ref().unwrap();
        let demo = HashMap::new();
        let mut enc = r.device.create_command_encoder(&Default::default());
        let progress = self.fade.as_ref().and_then(|f| f.progress(elapsed));
        match (progress, &mut self.fade) {
            (Some(progress), Some(f)) => {
                if f.targets.is_none() {
                    f.targets = Some((r.make_target(cw, ch, wgpu::TextureUsages::empty()),
                                      r.make_target(cw, ch, wgpu::TextureUsages::empty())));
                }
                let (a, b) = f.targets.as_ref().unwrap();
                r.encode_frame(&mut enc, a, &f.baked, elapsed, &f.config, events, &demo);
                r.encode_frame(&mut enc, b, baked, elapsed, c, events, &demo);
                r.encode_transition(&mut enc, cells, a, b, progress, f.seed, f.style, &f.config, c);
            }
            _ => {
                self.fade = None;
                r.encode_frame(&mut enc, cells, baked, elapsed, c, events, &demo);
            }
        }
        let view = frame.texture.create_view(&Default::default());
        r.encode_present(&mut enc, cells, &view, self.format, self.size, px);
        r.queue.submit([enc.finish()]);
        frame.present();
    }

    /// Keeps the bake on screen as the outgoing frame (WallpaperView.startFade). With nothing of
    /// the old look on screen yet, there's nothing to fade from, so the switch just cuts.
    fn start_fade(&mut self, from: &WallpaperConfig, start: f64, seconds: f64, style: TransitionStyle) {
        self.fade = match &self.baked {
            Some(old) if seconds > 0.0 && old.matches(from) => Some(Fade {
                baked: old.clone(),
                config: from.clone(),
                start,
                duration: seconds,
                seed: random_seed(),
                style,
                targets: None,
            }),
            _ => None,
        };
    }

    /// Paused partway through a transition: ends it, so the next frame drawn is the new look.
    fn end_fade(&mut self) -> bool {
        self.fade.take().is_some()
    }
}

/// A different pattern or direction for each screen's transition, 0 to 100 like the Mac's.
fn random_seed() -> f32 {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    // spread the clock's low bits over the range with a multiplicative hash
    (n.wrapping_mul(2_654_435_761) % 100_000) as f32 / 1000.0
}

/// Starts a schedule transition from `from` on every screen, over `seconds` (0 cuts). Call it
/// just before the config switches to the new look; Random is resolved here, once, so every
/// screen plays the same style (ConfigStore.transition does it as the switch is made).
pub fn start_transition(screens: &mut [Screen], r: &Renderer, from: &WallpaperConfig, seconds: f64, style: TransitionStyle) {
    let style = style.resolved();
    let start = r.elapsed();
    for s in screens {
        s.start_fade(from, start, seconds, style);
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

fn build_screens(r: &Renderer) -> Vec<Screen> {
    let Some(host) = find_desktop_host() else {
        eprintln!("deepfield: could not find the desktop window behind the icons");
        return Vec::new();
    };
    monitors().into_iter().filter_map(|m| Screen::new(r, &host, m)).collect()
}

/// Explorer keeps the last frame we drew behind the icons; setting the wallpaper again repaints it.
fn restore_desktop() {
    unsafe {
        let mut path = [0u16; 260];
        if SystemParametersInfoW(SPI_GETDESKWALLPAPER, path.len() as u32, Some(path.as_mut_ptr() as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0)).is_ok() {
            let _ = SystemParametersInfoW(SPI_SETDESKWALLPAPER, 0, Some(path.as_mut_ptr() as *mut _), SPIF_SENDCHANGE);
        }
    }
}

/// Battery saver on: the frame rate caps at 12, like Low Power Mode on a Mac.
fn power_saving() -> bool {
    let mut s = SYSTEM_POWER_STATUS::default();
    unsafe { GetSystemPowerStatus(&mut s).is_ok() && s.SystemStatusFlag == 1 }
}

/// Whether the foreground window fills the monitor it's on (a game or video full screen),
/// so nobody can see the wallpaper and it can stop drawing.
fn fullscreen_app_covers() -> bool {
    unsafe {
        let fg = GetForegroundWindow();
        if fg.is_invalid() {
            return false;
        }
        let mut class = [0u16; 64];
        let n = GetClassNameW(fg, &mut class) as usize;
        let name = String::from_utf16_lossy(&class[..n]);
        if name == "Progman" || name == "WorkerW" || name == "Shell_TrayWnd" {
            return false;
        }
        let mut wr = RECT::default();
        if GetWindowRect(fg, &mut wr).is_err() {
            return false;
        }
        let m = MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !GetMonitorInfoW(m, &mut info).as_bool() {
            return false;
        }
        let r = info.rcMonitor;
        wr.left <= r.left && wr.top <= r.top && wr.right >= r.right && wr.bottom >= r.bottom
    }
}

pub fn run() -> Result<(), String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let class = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: instance.into(),
            lpszClassName: w!("DeepFieldWallpaper"),
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            ..Default::default()
        };
        RegisterClassW(&class);
    }
    let r = Renderer::new()?;
    eprintln!("deepfield: rendering on {} ({:?})", r.adapter_info.name, r.adapter_info.backend);
    let mut store = ConfigStore::load();
    // every scene ready before it is picked, the current one first
    r.warm(store.config.scene, &[Renderer::scene_format(&store.config)], 6);
    let mut tray = Tray::new(&store.config);
    let mut presets = crate::presets::PresetStore::load();
    let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1);
    let events = EventSchedule::new(seed);
    let mut screens = build_screens(&r);
    let mut schedules = ScheduleStore::load();
    let mut sched_state = ScheduleState::load_from(&ScheduleState::path());
    tray.update_schedule(&schedules.schedule);
    // the first switch cuts straight over, since nothing is on screen yet
    run_schedule(&schedules, &mut sched_state, &mut store, &presets, &mut screens, &r, false);
    let mut paused = false;
    let mut next = Instant::now();
    let mut last_config_check = Instant::now();
    // the display link never ticks faster than its display on the Mac; with Mailbox nothing
    // here holds frames back, so the fastest display's refresh rate caps the frame rate
    let mut fastest_display = display_rates().into_iter().max().unwrap_or(60);

    'run: loop {
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, HWND::default(), 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    break 'run;
                }
                if msg.message == WM_DEEPFIELD_REBUILD {
                    screens.clear();
                    screens = build_screens(&r);
                    fastest_display = display_rates().into_iter().max().unwrap_or(60);
                    continue;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        while let Some(action) = tray.poll() {
            match action {
                TrayAction::Customize => crate::tray::open_customize(),
                TrayAction::Scene(s) => {
                    store.config.set_scene(s);
                    store.save();
                }
                TrayAction::PixelSize(n) => {
                    store.config.pixel_size = n;
                    store.save();
                }
                TrayAction::Preset(id) => {
                    if let Some(p) = presets.by_id(&id) {
                        store.config = p.applied(&store.config);
                        store.save();
                    }
                }
                TrayAction::Request(r) => crate::tray::request_customize(r),
                TrayAction::ToggleSchedule => {
                    if schedules.schedule.entries.is_empty() {
                        crate::tray::request_customize("show-schedule");
                    } else {
                        let mut s = schedules.schedule.clone();
                        s.enabled = !s.enabled;
                        if let Some(old) = schedules.set(s) {
                            schedule_changed(&old, &schedules, &mut sched_state);
                            run_schedule(&schedules, &mut sched_state, &mut store, &presets, &mut screens, &r, true);
                        }
                    }
                    tray.update_schedule(&schedules.schedule);
                }
                TrayAction::SkipSchedule => {
                    if let Some(s) = schedules.schedule.skipped(schedule::now(), &SystemCalendar) {
                        if let Some(old) = schedules.set(s) {
                            schedule_changed(&old, &schedules, &mut sched_state);
                            run_schedule(&schedules, &mut sched_state, &mut store, &presets, &mut screens, &r, true);
                        }
                    }
                }
                TrayAction::TogglePause => paused = !paused,
                TrayAction::EditSettings => crate::tray::open(store.path().as_os_str()),
                TrayAction::Quit => break 'run,
            }
            tray.update(&store.config, paused);
            tray.update_presets(&presets, &store.config);
        }
        if last_config_check.elapsed() > Duration::from_secs(1) {
            last_config_check = Instant::now();
            if store.reload_if_changed() {
                tray.update(&store.config, paused);
                tray.update_presets(&presets, &store.config);
            }
            // the schedule edited in the Customize window
            if let Some(old) = schedules.reload_if_changed() {
                schedule_changed(&old, &schedules, &mut sched_state);
                tray.update_schedule(&schedules.schedule);
            }
            // Each second, rather than only at the next switch's time: that also catches waking
            // from sleep, a new clock time or time zone, and an edit. A slot switches only once.
            if schedules.schedule.enabled {
                run_schedule(&schedules, &mut sched_state, &mut store, &presets, &mut screens, &r, true);
                tray.update(&store.config, paused);
                tray.update_presets(&presets, &store.config);
            }
            // presets saved, renamed or deleted in the Customize window
            if presets.reload_if_changed() {
                tray.set_presets(&presets, &store.config);
            }
        }

        let now = Instant::now();
        if now >= next {
            let mut fps = store.config.fps.clamp(1, fastest_display.max(1)) as u32;
            if power_saving() {
                fps = fps.min(12);
            }
            let interval = Duration::from_secs_f64(1.0 / fps as f64);
            next += interval;
            if next < now {
                next = now + interval; // fell behind (sleep, a slow bake): don't race to catch up
            }
            if !paused && !fullscreen_app_covers() && store.config.scene.is_ported() {
                let elapsed = r.elapsed();
                for s in &mut screens {
                    s.draw(&r, &store, &events, elapsed);
                }
            } else if paused && !fullscreen_app_covers() && store.config.scene.is_ported() {
                // Paused partway through a transition: end on the new look. Covered by a full
                // screen app this waits until it shows again, so nothing is drawn unseen.
                let elapsed = r.elapsed();
                for s in &mut screens {
                    if s.end_fade() {
                        s.draw(&r, &store, &events, elapsed);
                    }
                }
            }
        }
        let wait = next.saturating_duration_since(Instant::now()).as_millis() as u32;
        unsafe {
            MsgWaitForMultipleObjects(None, false, wait.min(INFINITE - 1), QS_ALLINPUT);
        }
    }
    drop(screens);
    restore_desktop();
    Ok(())
}

unsafe extern "system" fn ask_to_quit(hwnd: HWND, found: LPARAM) -> BOOL {
    let mut class = [0u16; 64];
    let n = GetClassNameW(hwnd, &mut class) as usize;
    if String::from_utf16_lossy(&class[..n]) == "DeepFieldWallpaper" {
        let _ = PostMessageW(hwnd, WM_DEEPFIELD_QUIT, WPARAM(0), LPARAM(0));
        *(found.0 as *mut bool) = true;
    }
    TRUE
}

/// `deepfield --quit`: asks a running copy to stop (it puts the desktop back as it goes).
/// The wallpaper windows are children of Explorer's desktop windows, so search every window.
pub fn quit_running() -> bool {
    let mut found = false;
    unsafe {
        let _ = EnumChildWindows(GetDesktopWindow(), Some(ask_to_quit), LPARAM(&mut found as *mut bool as isize));
    }
    found
}

/// Runs the schedule now (Scheduler.evaluate): switches with a transition when an entry is due,
/// and records the switch for the Customize window's status line.
fn run_schedule(schedules: &ScheduleStore, state: &mut ScheduleState, store: &mut ConfigStore, presets: &PresetStore,
                screens: &mut [Screen], r: &Renderer, fade: bool) {
    let before = state.clone();
    let e = schedule::evaluate(&schedules.schedule, schedule::now(), &store.config, &presets.presets, state, fade,
                               &SystemCalendar);
    if let Some(sw) = e.switch {
        start_transition(screens, r, &store.config, sw.seconds, sw.style);
        store.config = sw.config;
        store.save();
    }
    if *state != before {
        state.save_to(&ScheduleState::path());
    }
}

/// Turning the schedule on shows the current entry now, even if its slot was already shown.
fn schedule_changed(old: &WallpaperSchedule, schedules: &ScheduleStore, state: &mut ScheduleState) {
    if schedules.schedule.enabled && !old.enabled {
        state.last_slot = None;
    }
}
