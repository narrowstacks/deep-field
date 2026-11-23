# Deep Field for Windows

A port of Deep Field to Windows 10 and 11: the same scenes, drawn live behind the desktop icons
on every monitor. Rust and wgpu (Direct3D 12), with the Metal shaders translated to WGSL.

This is an early port. Three scenes run so far: **Black Hole**, **Binary Stars** and **Gas Giant
Storms**. Their snapshots match the macOS reference renders in `docs/media/gallery`. The other
scenes, the Customize window, schedules, transitions, the lock screen still and phone exports are
still to come (`deepfield --list-scenes` shows what's ported).

## Build and run

You need Rust (stable, MSVC toolchain).

```powershell
cd windows
cargo build --release
.\target\release\deepfield.exe
```

A tray icon appears in the notification area: pick a scene or pixel size, pause, open the
settings file, or quit. Settings live in `%APPDATA%\DeepField\config.json`, with the same keys as
the macOS app's saved config, so a config exported from a Mac reads here. Edits to the file show
up within a second.

The wallpaper pauses while a full-screen app has the focus, and drops to 12 fps with battery
saver on.

## Command line

```
deepfield --snapshot out.png --defaults --scene blackHole --size 1720x720 --time 300
deepfield --benchmark --defaults --scene gasGiant --size 3840x2160
deepfield --list-scenes
deepfield --check-shaders
deepfield --quit
```

`--snapshot` takes `--config FILE`, `--no-events` and `--demo ID:START` like the macOS dev
command line. Snapshots are deterministic (events use seed 1), so they can be compared with the
Mac's. `--benchmark` reports GPU time per frame from timestamp queries; keep it under about 2 ms.
`DEEPFIELD_TRACE=1` prints startup progress, and `WGPU_BACKEND=vulkan` picks Vulkan instead of
Direct3D 12 (at the time of writing NVIDIA's Vulkan driver crashed building a pipeline here).

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
2. Port its builder in `Scenes/SceneParams.swift` to `src/scene_params.rs`.
3. Add its fragment entry to `Renderer::fragment_name` and mark it in `SceneKind::is_ported`.
4. Render a snapshot at the gallery's settings
   (`--size 960x600 --time 60 --defaults`, pixel size 3) and compare it with
   `docs/media/gallery/<scene>.png`.
