//! Deep Field for Windows: animated, pixel-dithered space scenes as the desktop wallpaper.
//! Two executables share this library: `deepfield` (a console program: the command line) and
//! `deepfield-wallpaper` (a windowed program: the live wallpaper and its tray icon), the way the
//! macOS app pairs DeepField.app with its `deepfield` command.

pub mod astronomy;
pub mod blue_noise;
pub mod camera;
pub mod capture;
pub mod color_presets;
pub mod config;
pub mod customization;
pub mod config_store;
pub mod earth_maps;
pub mod events;
pub mod historical_clouds;
pub mod live_earth_feeds;
pub mod gpu_types;
pub mod math;
pub mod palette;
pub mod presets;
pub mod planets;
pub mod renderer;
pub mod scene_params;
pub mod schedule;
pub mod scenes;
pub mod shader;
pub mod sky_cover;
pub mod sky_planets;
pub mod star_system;
pub mod transition;
pub mod tray;
pub mod wallpaper;

const USAGE: &str = "\
Deep Field for Windows

  deepfield                      start the live wallpaper (tray icon to change scenes or quit)
  deepfield --snapshot OUT.png   render one frame to a PNG
      [--scene KIND] [--size WxH] [--time SECONDS] [--defaults | --config FILE]
      [--preset NAME|FILE]       a saved preset, palette, scene color preset or .deepfield file
      [--transition-from SCENE:PROGRESS[:STYLE]]
                                 a frame partway (0 to 1) through a schedule transition from SCENE
      [--no-events] [--demo NAME:START,...]
      [--live-earth-cache]       Live Earth: the last fetched clouds and aurora, not the bundled ones
      [--earth-timelapse N]      Live Earth: its clock runs N times as fast from its moment
  deepfield --fetch-live-earth   fetch Live Earth's cloud map and aurora forecast into the cache
  deepfield --prefetch-history SECONDS --config FILE
                                 fetch real past clouds for a frozen Live Earth moment and after it
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
