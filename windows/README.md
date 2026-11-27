# Deep Field for Windows

A port of Deep Field to Windows 10 and 11: the same scenes, drawn live behind the desktop icons
on every monitor. Rust and wgpu (Direct3D 12), with the Metal shaders translated to WGSL.

This is an early port. All 21 listed scenes run, and their snapshots match the macOS reference
renders in `docs/media/gallery`. Still to come: the lock screen still and phone exports, and Live
Earth following the device's location (it uses the home latitude and longitude from the
settings).

Aurora from Orbit and Live Earth read the Earth maps in `Resources\Earth`: from an `Earth`
folder beside the executable, or, for a build in the repo, found by walking up from it. Live
Earth fetches the latest cloud map and aurora forecast in the background while it shows, and a
frozen moment in the past fetches that day's real clouds; all of it is cached in
`%APPDATA%\DeepField\LiveEarth`. Command-line renders never fetch the live maps (they use the
bundled copies, or the cached ones with `--live-earth-cache`), but do wait for a past moment's
clouds.

## Build and run

You need Rust (stable, MSVC toolchain).

```powershell
cd windows
cargo build --release
.\target\release\deepfield.exe
```

That builds two programs: `deepfield.exe`, the command line (a console program), and
`deepfield-wallpaper.exe`, the wallpaper itself (a windowed program, so starting it at login opens
no console). `deepfield` with no arguments starts the wallpaper and returns. For a build to hand
out, use `cargo build --profile dist` (thin LTO; plain release builds skip it to stay quick).

A tray icon appears in the notification area: pick a scene, preset or pixel size, turn the
schedule on or skip ahead, pause, open the settings file, or quit. Settings live in
`%APPDATA%\DeepField\config.json`, with the same keys as the macOS app's saved config, so a
config exported from a Mac reads here. Edits to the file show up within a second.

The wallpaper pauses while a full-screen app has the focus, and drops to 12 fps with battery
saver on.

## Customize window

`deepfield-settings.exe` is the Customize window, after the macOS one: a live preview of the
current look with the scene gallery under it, and Scene, Sky, Image and System sections beside
it. It's built with [GPUI](https://www.gpui.rs) through
[gpui-kit](https://github.com/longbridge/gpui-kit), in its own crate so GPUI's dependencies stay
out of the wallpaper's build:

```powershell
cd windows\settings
cargo build --release
.\target\release\deepfield-settings.exe
```

It edits `%APPDATA%\DeepField\config.json` (written whole and renamed into place, so the
wallpaper never reads half a file), and picks up changes made there by the tray menu or by hand.
The preview renders with the same library as the wallpaper, on a thread of its own. Only one
copy runs; opening it again brings the window forward. Ctrl+1 to Ctrl+4 and Ctrl+6 (Schedule) pick a section and
Ctrl+[ and Ctrl+] step through the scenes.

The tray menu's Customize item starts `deepfield-settings.exe` from the wallpaper's own folder,
falling back to `..\..\settings\target\<profile>` while developing. A packaged build should put
`deepfield.exe`, `deepfield-wallpaper.exe` and `deepfield-settings.exe` side by side. The
System section's start-at-login switch adds a `Deep Field` value under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` pointing at `deepfield-wallpaper.exe`
(found the same way).

The Presets menu under the section picker saves the current look under a name, applies, renames
and deletes presets, and imports and exports `.deepfield` files, the same files the Mac app reads
and writes. Presets live in `%APPDATA%\DeepField\presets.json` (the Mac's own list format), and
the tray menu lists them too; its Save, Import and Export open this window with that dialog
showing (asked through a `customize-request` file in the same folder).

The Schedule section rotates through presets and scenes, or switches at set times on chosen
days, each switch moving into the next with one of the Mac's transitions. It's kept in
`%APPDATA%\DeepField\schedule.json`, in the Mac's format; the wallpaper runs it (the tray menu
can turn it on and skip ahead) and records each switch in `schedule-state.json` for the status
line.

Show Me buttons (beside Supernovae and Comets, and under each scene's Events) start an event
now, in the preview and the running wallpaper at once: the start goes through `demo.json` as
wall-clock time, since the two programs keep their own clocks. A supernova or comet that would
be hidden behind the scene, or lost in a bright sky, says so instead, as on the Mac.

Not there yet: Phone and the lock screen still.

## Command line

```
deepfield --snapshot out.png --defaults --scene blackHole --size 1720x720 --time 300
deepfield --benchmark --defaults --scene gasGiant --size 3840x2160
deepfield --list-scenes
deepfield --check-shaders
deepfield --quit
```

`--snapshot` takes `--config FILE`, `--preset NAME|FILE`, `--no-events` and `--demo NAME:START` (repeatable, or comma-separated) like the macOS dev
command line. Snapshots are deterministic (events use seed 1), so they can be compared with the
Mac's. `--transition-from SCENE:PROGRESS[:STYLE]` renders a frame that far (0 to 1) into a
schedule transition from SCENE to the configured look (styles: dissolve, crossfade, pan,
driftAway, warp, blackHole, random; dissolve by default), with seed 1 like the Mac's.
`--benchmark` reports GPU time per frame from timestamp queries; keep it under about 2 ms.
`DEEPFIELD_SHADERS=shaders` loads the WGSL from that folder instead of the copy built in, so
shader edits show up without a rebuild. `DEEPFIELD_TRACE=1` prints startup progress, and
`WGPU_BACKEND=vulkan` picks Vulkan instead of Direct3D 12 (at the time of writing NVIDIA's Vulkan
driver crashed building a pipeline here).

Shaders compile with DXC when `dxcompiler.dll` and `dxil.dll` sit beside the program or in a
Windows SDK (`C:\Program Files (x86)\Windows Kits\10\bin\<version>\x64`), and with the much
slower FXC otherwise (Eclipse alone takes about 10 seconds), so a packaged build should ship
both DLLs. Each scene's pipeline still takes about half a second to translate, so the wallpaper
and the Customize window compile every scene in parallel at startup (`Renderer::warm`), the
current one first: all of them are ready in about two seconds.

## How it fits together

- `src/renderer.rs` follows `Rendering/Renderer.swift`: the one-time ray bake and sky pass
  (compute), the scene's fragment pass, bloom, and a present pass that scales the frame up with
  nearest-neighbor filtering (DWM would smooth a stretched swap chain).
- `shaders/` holds the WGSL, one file per Metal file. `shaders/README.md` has the module layout
  and the rules for translating MSL. Bake lookups that Metal packs into 16-bit normalized
  textures are float textures here, since WebGPU can't write those formats from a compute shader.
- `src/config.rs`, `camera.rs`, `planets.rs`, `star_system.rs`, `events.rs`, `palette.rs` and
  `scene_params.rs` are ports of the Swift scene model, with the same numbers and hashing.
- `src/wallpaper.rs` hosts a child window per monitor behind the icons. Explorer splits off a
  WorkerW window when Progman gets message 0x052C; before Windows 11 24H2 that WorkerW is
  top-level and the wallpaper is parented to it, and from 24H2 on it's a child of Progman and
  the wallpaper goes into Progman just below the icon view.

## Porting a scene

1. Translate `Sources/DeepField/Rendering/Shaders/Shader<Name>.swift` into `shaders/<name>.wgsl`
   (see `shaders/README.md`) and add it to `FRAME` in `src/shader.rs`.
2. Port its builder in `Scenes/SceneParams.swift` to `src/scenes/<scene>.rs` (the dispatch in
   `src/scene_params.rs` calls it).
3. Check its fragment entry in `Renderer::fragment_name` and mark it in `SceneKind::is_ported`.
4. Render a snapshot at the gallery's moment and settings (the `SCENES` list in
   `Design/Brand/media.py`; `--size 960x600`, pixel size 3) and compare it with
   `docs/media/gallery/<scene>.png`.
