//! Windows plumbing: start at login, the wallpaper process, and one settings window at a time.

use std::path::PathBuf;

use windows::core::{HSTRING, PCWSTR};
use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, HWND};
use windows::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_READ,
    KEY_SET_VALUE, REG_SZ,
};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::WindowsAndMessaging::{
    FindWindowW, IsIconic, SetForegroundWindow, ShowWindow, SW_RESTORE,
};

pub const WINDOW_TITLE: &str = "Customize Deep Field";
/// The same window's title while it shows the welcome guide.
pub const WELCOME_TITLE: &str = "Welcome to Deep Field";
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Deep Field";

/// Holds a named mutex for the life of the process. When another copy already holds it, brings
/// that copy's window forward and returns false.
pub fn claim_single_instance() -> bool {
    unsafe {
        let name = HSTRING::from("Local\\DeepFieldSettings");
        let handle = CreateMutexW(None, true, &name);
        if handle.is_ok() && GetLastError() != ERROR_ALREADY_EXISTS {
            // leaked on purpose: the mutex lives until the process exits
            std::mem::forget(handle);
            return true;
        }
        if let Some(hwnd) = window() {
            focus(hwnd);
        }
        false
    }
}

fn focus(hwnd: HWND) {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd);
    }
}

/// deepfield-wallpaper.exe: beside this program in a packaged build, or in the main crate's
/// target folder while developing (this crate builds to windows\settings\target\<profile>).
pub fn wallpaper_exe() -> Option<PathBuf> {
    let here = std::env::current_exe().ok()?;
    let dir = here.parent()?;
    let beside = dir.join("deepfield-wallpaper.exe");
    if beside.exists() {
        return Some(beside);
    }
    let profile = dir.file_name()?.to_owned();
    let dev = dir.parent()?.parent()?.parent()?.join("target").join(profile).join("deepfield-wallpaper.exe");
    dev.exists().then_some(dev)
}

fn open_run_key(access: windows::Win32::System::Registry::REG_SAM_FLAGS) -> Option<HKEY> {
    let mut key = HKEY::default();
    let ok = unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, &HSTRING::from(RUN_KEY), 0, access, &mut key) };
    ok.is_ok().then_some(key)
}

/// The command the Run entry holds, if there is one.
pub fn login_item() -> Option<String> {
    let key = open_run_key(KEY_READ)?;
    let name = HSTRING::from(RUN_VALUE);
    let mut size = 0u32;
    let mut out = None;
    unsafe {
        if RegQueryValueExW(key, &name, None, None, None, Some(&mut size)).is_ok() && size > 0 {
            let mut buf = vec![0u8; size as usize];
            if RegQueryValueExW(key, &name, None, None, Some(buf.as_mut_ptr()), Some(&mut size)).is_ok() {
                let wide: Vec<u16> = buf.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
                out = Some(String::from_utf16_lossy(&wide).trim_end_matches('\0').to_string());
            }
        }
        let _ = RegCloseKey(key);
    }
    out
}

/// Adds or removes the HKCU Run entry that starts the wallpaper at login.
pub fn set_login_item(on: bool) -> Result<(), String> {
    let key = open_run_key(KEY_SET_VALUE).ok_or("could not open the Run key")?;
    let name = HSTRING::from(RUN_VALUE);
    let result = unsafe {
        if on {
            let exe = wallpaper_exe().ok_or("deepfield-wallpaper.exe wasn't found next to this program")?;
            let cmd = format!("\"{}\"", exe.display());
            let wide: Vec<u16> = cmd.encode_utf16().chain(std::iter::once(0)).collect();
            let bytes = std::slice::from_raw_parts(wide.as_ptr() as *const u8, wide.len() * 2);
            RegSetValueExW(key, &name, 0, REG_SZ, Some(bytes)).ok().map_err(|e| e.to_string())
        } else {
            let r = RegDeleteValueW(key, &name);
            // nothing to delete is fine
            if r.is_ok() || r == windows::Win32::Foundation::ERROR_FILE_NOT_FOUND { Ok(()) } else { Err(format!("{r:?}")) }
        }
    };
    unsafe {
        let _ = RegCloseKey(key);
    }
    result
}

/// Opens a folder or file with its default app.
pub fn open(path: &std::path::Path) {
    let _ = std::process::Command::new("explorer").arg(path).spawn();
}

/// This program's window, found by its title (GPUI doesn't hand out the handle).
pub fn window() -> Option<HWND> {
    [WINDOW_TITLE, WELCOME_TITLE]
        .into_iter()
        .find_map(|t| unsafe { FindWindowW(PCWSTR::null(), &HSTRING::from(t)).ok() })
}

/// Asks for the dark title bar, to match the window's dark contents.
pub fn dark_title_bar() {
    use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE};
    if let Some(hwnd) = window() {
        let on: i32 = 1;
        unsafe {
            let _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &on as *const i32 as *const _, 4);
        }
    }
}

pub fn is_minimized(hwnd: HWND) -> bool {
    unsafe { IsIconic(hwnd).as_bool() }
}

/// The primary screen in pixels: the preview renders what the wallpaper there would show.
pub fn screen_size() -> (u32, u32) {
    use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN};
    let (w, h) = unsafe { (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)) };
    if w > 0 && h > 0 { (w as u32, h as u32) } else { (2560, 1440) }
}

/// The user's locale's weekday names, for the schedule's day buttons: (shortest, full) for each
/// day as the schedule counts them, index 0 = Sunday ... 6 = Saturday.
pub fn weekday_names() -> Vec<(String, String)> {
    use windows::Win32::Globalization::{GetLocaleInfoEx, LOCALE_SDAYNAME1, LOCALE_SSHORTESTDAYNAME1};
    const FALLBACK: [(&str, &str); 7] = [("S", "Sunday"), ("M", "Monday"), ("T", "Tuesday"), ("W", "Wednesday"),
                                         ("T", "Thursday"), ("F", "Friday"), ("S", "Saturday")];
    let info = |lctype: u32| -> Option<String> {
        let mut buf = [0u16; 80];
        let n = unsafe { GetLocaleInfoEx(PCWSTR::null(), lctype, Some(&mut buf)) };
        (n > 1).then(|| String::from_utf16_lossy(&buf[..n as usize - 1]))
    };
    (0..7)
        .map(|i| {
            // Windows numbers its day names from Monday (1) to Sunday (7)
            let win = (i + 6) % 7;
            let short = info(LOCALE_SSHORTESTDAYNAME1 + win).unwrap_or_else(|| FALLBACK[i as usize].0.into());
            let full = info(LOCALE_SDAYNAME1 + win).unwrap_or_else(|| FALLBACK[i as usize].1.into());
            (short, full)
        })
        .collect()
}

/// The first day of the week in the user's locale, as the schedule counts days (1 = Sunday).
pub fn first_weekday() -> i64 {
    use windows::Win32::Globalization::{GetLocaleInfoEx, LOCALE_IFIRSTDAYOFWEEK};
    let mut buf = [0u16; 4];
    let n = unsafe { GetLocaleInfoEx(PCWSTR::null(), LOCALE_IFIRSTDAYOFWEEK, Some(&mut buf)) };
    // "0" is Monday ... "6" is Sunday
    let monday_based = if n > 1 { (buf[0] as i64 - '0' as i64).clamp(0, 6) } else { 6 };
    (monday_based + 1) % 7 + 1
}
