// `deepfield`: the command line. A console program, so shells wait for it and see its output.
// With no arguments it starts the wallpaper (deepfield-wallpaper.exe, next to it) and returns.

fn main() {
    deepfield::run_with_big_stack(|| {
        let args: Vec<String> = std::env::args().skip(1).collect();
        if !args.is_empty() {
            return deepfield::run_cli(&args);
        }
        let app = std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.join("deepfield-wallpaper.exe")));
        match app.map(|a| std::process::Command::new(&a).spawn().map(|_| a)) {
            Some(Ok(a)) => {
                println!("Deep Field is running ({}). Use the tray icon, or `deepfield --quit`, to stop it.", a.display());
                0
            }
            _ => {
                eprintln!("deepfield: could not start deepfield-wallpaper.exe (it belongs next to deepfield.exe)");
                1
            }
        }
    })
}
