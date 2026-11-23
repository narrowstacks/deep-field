//! Deep Field for Windows: animated, pixel-dithered space scenes as the desktop wallpaper.
//! Two executables share this library: `deepfield` (a console program: the command line) and
//! `deepfield-wallpaper` (a windowed program: the live wallpaper and its tray icon), the way the
//! macOS app pairs DeepField.app with its `deepfield` command.

pub mod blue_noise;
pub mod camera;
pub mod capture;
pub mod config;
pub mod config_store;
pub mod events;
pub mod gpu_types;
pub mod math;
pub mod palette;
pub mod planets;
pub mod renderer;
pub mod scene_params;
pub mod scenes;
pub mod shader;
pub mod star_system;
pub mod tray;
pub mod wallpaper;

const USAGE: &str = "\
Deep Field for Windows

  deepfield                      start the live wallpaper (tray icon to change scenes or quit)
  deepfield --snapshot OUT.png   render one frame to a PNG
      [--scene KIND] [--size WxH] [--time SECONDS] [--defaults | --config FILE]
      [--no-events] [--demo ID:START]
  deepfield --benchmark          time frames of a scene  [--scene KIND] [--size WxH] [--frames N]
  deepfield --quit               stop a running wallpaper
  deepfield --list-scenes        scene kinds (ported ones marked)
  deepfield --check-shaders      validate the WGSL
";

pub fn usage() -> &'static str {
    USAGE
}

/// Runs `f` on a thread with a 64 MB stack and exits with its code. Shader translation recurses
/// deeply on big shaders, past the 1 MB main-thread stack Windows gives.
pub fn run_with_big_stack(f: fn() -> i32) -> ! {
    let code = std::thread::Builder::new()
        .stack_size(64 << 20)
        .spawn(f)
        .expect("main thread")
        .join()
        .unwrap_or(1);
    std::process::exit(code);
}

/// The command line; returns the exit code.
pub fn run_cli(args: &[String]) -> i32 {
    match capture::run_cli(args) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("deepfield: {e}");
            if e.starts_with("usage") {
                eprint!("{USAGE}");
            }
            1
        }
    }
}

/// The live wallpaper; errors show in a message box, since it has no console.
pub fn run_wallpaper() -> i32 {
    if let Err(e) = wallpaper::run() {
        error_box(&e);
        return 1;
    }
    0
}

pub fn error_box(msg: &str) {
    use windows::core::HSTRING;
    use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};
    unsafe {
        MessageBoxW(None, &HSTRING::from(msg), &HSTRING::from("Deep Field"), MB_OK | MB_ICONERROR);
    }
}
