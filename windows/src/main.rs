// Deep Field for Windows: animated, pixel-dithered space scenes as the desktop wallpaper.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod blue_noise;
mod camera;
mod capture;
mod config;
mod config_store;
mod events;
mod gpu_types;
mod math;
mod palette;
mod planets;
mod renderer;
mod scene_params;
mod shader;
mod star_system;
mod tray;
mod wallpaper;

const USAGE: &str = "\
Deep Field for Windows

  deepfield                      run the live wallpaper (tray icon to change scenes or quit)
  deepfield --snapshot OUT.png   render one frame to a PNG
      [--scene KIND] [--size WxH] [--time SECONDS] [--defaults | --config FILE]
      [--no-events] [--demo ID:START]
  deepfield --benchmark          time frames of a scene  [--scene KIND] [--size WxH] [--frames N]
  deepfield --quit               stop a running wallpaper
  deepfield --list-scenes        scene kinds (ported ones marked)
  deepfield --check-shaders      validate the WGSL
";

fn main() {
    // Shader translation recurses deeply on big shaders, past the 1 MB main-thread stack Windows gives.
    let code = std::thread::Builder::new()
        .stack_size(64 << 20)
        .spawn(real_main)
        .expect("main thread")
        .join()
        .unwrap_or(1);
    std::process::exit(code);
}

fn real_main() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if !args.is_empty() {
        attach_console();
        return match capture::run_cli(&args) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("deepfield: {e}");
                if e.starts_with("usage") {
                    eprint!("{USAGE}");
                }
                1
            }
        };
    }
    if let Err(e) = wallpaper::run() {
        error_box(&e);
        return 1;
    }
    0
}

pub fn usage() -> &'static str {
    USAGE
}

/// A GUI-subsystem build has no console of its own; borrow the one it was started from, so the
/// command-line modes can print.
fn attach_console() {
    unsafe {
        let _ = windows::Win32::System::Console::AttachConsole(windows::Win32::System::Console::ATTACH_PARENT_PROCESS);
    }
}

fn error_box(msg: &str) {
    use windows::core::HSTRING;
    use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};
    unsafe {
        MessageBoxW(None, &HSTRING::from(msg), &HSTRING::from("Deep Field"), MB_OK | MB_ICONERROR);
    }
}
