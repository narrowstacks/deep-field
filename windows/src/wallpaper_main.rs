// `deepfield-wallpaper`: the live wallpaper and its tray icon. A windowed program, so starting it
// (at login, or from Explorer) doesn't open a console.
#![windows_subsystem = "windows"]

fn main() {
    deepfield::run_with_big_stack(deepfield::run_wallpaper)
}
