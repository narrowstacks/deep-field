# Deep Field

An animated macOS desktop background rendered with ordered (Bayer) dithering at a chunky pixel
size. Pick a scene:

- **Black Hole**: a lensed accretion disk, redshifted orange on one side and blueshifted on the
  other, with a photon ring. Planets orbiting it get bent by its gravity as they pass behind.
- **Wormhole**: a crystal-ball throat showing another universe and its galaxy. The light of our
  own sky wraps around its edge. Now and then something falls in or comes out, a flare runs
  along the rim, or a supernova goes off on the far side.
- **Binary Stars** and **Trinary Stars**: real star types (red dwarf to blue giant, white dwarf,
  neutron star) with granulation, sunspots, coronas and eclipses. Planets are lit by every star.
- **Galaxy**: spiral, barred spiral, elliptical, irregular or ring, with a dust-laned disk, a
  bulge that sits partly in front of and partly behind the disk, and a halo of globular clusters.
- **Star Meets Black Hole**: a tidally stretched, egg-shaped star beside the hole is stripped
  into a glowing stream that feeds the existing accretion disk, with a bright shock where it
  hits the rim and optional jets. Star, stream and jets are all lensed. Star type, size and
  distance, stream brightness, disk colors and jets are adjustable.
- **Pulsar**: a spinning neutron star with lighthouse beams, dipole field lines, and a wind
  nebula (torus and jets). Period, magnetic angle, tilt, beam width and colors are adjustable.
- **Comet**: a coma with rotating jets, a blue ion tail combed into streamers, and a curved dust
  tail. Now and then it has an outburst, or a chunk of ion tail breaks off and drifts away.
- **Star Close-up**: the limb of a star with granulation, sunspots, a chromosphere with
  spicules, coronal loops and prominences, plus occasional flares and coronal mass ejections.

A nebula scene (pillars, dark clouds, planetary nebulae, supernova remnants) is in the code but
hidden from the scene list for now; see `SceneKind.isListed`.

Across every scene, background stars occasionally twinkle, a few pulsars blink, supernovae
flare up and leave light echoes, and comets drift past.

## Build and run

```bash
./build.sh && open build/DeepField.app
```

It lives in the menu bar (a circle icon). **Customize…** (⌘,) opens a window with a live preview
where you can change the scene, colors (presets plus color pickers), star density, event
frequency (with "Show me" buttons that trigger an event right away), planets, pixel size, color
levels, dither pattern and frame rate. Settings save automatically.

The Colors tab's **Image** section (exposure, contrast, saturation, highlight rolloff, black point,
vignette and bloom) works on the scene's light before it's tone mapped and dithered, so the result
always stays dithered, and it applies to the wallpaper, the lock screen still and phone exports
alike. Bloom is a bright pass and blur at a quarter of the shaded size; at 0 those passes don't
run at all.

A picked color is what that part shows where it's typically lit: `Config/PickedColor.swift`
runs the tone map, saturation and gamma backwards from the pick, at each element's measured
typical brightness, and darker shades are built around it rather than by squaring it. The
background sky's colors and the galaxy's dust stay tints.

## Phone wallpapers

The **Phone** tab of the Customize window turns the current scene into an iPhone wallpaper. Pick
a model (or a custom size) and it recomposes the scene for a tall frame, with the subject below
the Lock Screen clock; zoom and subject height adjust that, and a clock overlay shows where the
time will sit. It's dithered with the wallpaper's look (cells a notch larger than on the
desktop, or a size you pick) or smooth.

- **Still**: PNG or HEIC.
- **Live Photo**: a 3-second loop with events off and planets and star orbits held still, at 2x
  the wallpaper's speed by default so the motion shows. The pulsar's loop is a whole number of
  turns; elsewhere the last second dissolves, cell by cell along a Bayer threshold, into the
  frames before the start, so it loops without a jump. It's saved as a HEIC still plus a HEVC
  QuickTime movie that share a content identifier (the still's Apple maker note key 17, the
  movie's `com.apple.quicktime.content.identifier`, and a `still-image-time` metadata track at
  the middle frame). **Save Files…** writes the pair to a folder (AirDrop both together), and
  **Add to Photos** adds it to the Photos library as one Live Photo (asks for permission to add
  to Photos the first time), which reaches the iPhone through iCloud Photos.

What to expect on the iPhone: the Live Photo plays in Photos when you press and hold it. iOS 17
and later can play a Live Photo wallpaper on the Lock Screen, but they often refuse ones that
weren't taken with the Camera ("Motion not available"). Apple says the requirements are
undocumented, so there it's usually a still wallpaper.

## Galaxy rotation

Each star orbits at its own angular speed, ω(r) = v(r) / r, taken from a rotation curve:

- **With a dark matter halo** (the default), v(r) rises and then stays flat out to the edge, as
  observed in real galaxies.
- **Visible mass only** (toggle off), v(r) peaks near the center and falls off like v ∝ 1/√r. The
  outer disk visibly lags, which is what we'd expect without dark matter, and it isn't what we
  observe.

Spiral arms and bars are density waves that rotate rigidly at one pattern speed while stars
drift through them, so the arms don't wind up. Across an arm you see the order density-wave
theory predicts: dust lane on the inside edge, then pink star-forming regions, then young blue
stars. Dwarf irregulars turn almost like a solid body, matching their rising rotation curves.

## Why it's cheap

- **Rays are traced once.** The camera never moves, so each pixel's light path never changes. A
  compute pass traces every ray at startup (about 25 ms for the black hole) through
  Schwarzschild spacetime, an Ellis wormhole, or flat space. It stores where each ray hits the
  disk, where it crosses the planets' orbits, and which patch of sky it ends up seeing. A second
  pass measures how much sky each pixel covers and filters detail to match, so heavily lensed
  regions don't shimmer. Each frame only reads those lookups and animates on top of them, and
  lensing of planets, supernovae and comets comes for free.
- **Only the lookups a scene needs.** Each scene allocates just the bake textures it reads, in
  the smallest formats that hold its precision, and reuses them across re-bakes: about 8 MB per
  screen for flat-space scenes, up to about 44 MB for the black hole with planets.
- **Low resolution on purpose.** It renders at 1/3 of screen resolution by default and the
  compositor scales it up with nearest-neighbor filtering, so the GPU shades about 1/9 of the
  pixels.
- **Low frame rate.** 24 fps by default, capped at 12 in Low Power Mode and at 8 under thermal
  pressure.
- **Stops when nobody can see it.** The display link pauses when the wallpaper window is fully
  covered (`NSWindow.occlusionState`), when the displays sleep, and when you switch users.
- **Events are scheduled on the CPU** from a seeded hash per time slot, so there is no
  simulation state.

## Dev tools

```bash
.build/release/DeepField --snapshot out.png --time 444 [--size 3440x1440] [--scene wormhole] \
    [--preset Synthwave] [--config '{"galaxyType": "barred", "darkMatter": false}'] [--no-events] \
    [--demo 1:440]                                            # force event kind 1 to start at t=440 s
.build/release/DeepField --benchmark [--scene galaxy] [--size 3440x1440] [--frames 120]
.build/release/DeepField --list-events 60 --scene wormhole   # when events fire (seed 1)
.build/release/DeepField --mobile-export outdir [--device 17-pro-max|1179x2556] [--live] [--smooth] \
    [--phone-pixel 4] [--zoom 1.2] [--shift 0.05] [--speed 2] [--scene comet] [--defaults]
.build/release/DeepField --check-live still.HEIC movie.MOV   # pairing metadata, loads as a Live Photo?
build/DeepField.app/Contents/MacOS/DeepField --customize   # open the Customize window at launch
build/DeepField.app/Contents/MacOS/DeepField --check-picker outdir -captureTab 1   # drive the color wells, check the preview follows
defaults write local.deepfield.wallpaper debug -bool true     # log bake times, fps, pause/resume
```

`--defaults` starts from the default settings instead of your saved ones. `--mobile-export`
always writes the portrait still as `<name>.png` (deterministic); with `--live` it also writes
the Live Photo pair, prints its pairing metadata, checks that PhotoKit loads it as a Live Photo
(without touching the library), and writes `<name> preview.mp4`, the loop played three times.

Snapshots are deterministic, so comparing `md5` of a set of them before and after a change
shows whether the output moved. Event kind ids for `--demo` are listed in `Scenes/Events.swift`.

`--benchmark` renders every listed scene (or just `--scene`, hidden ones included) offscreen at
3440x1440 and the configured pixel size, and prints, per scene, the GPU time of a bake (ray trace
plus sky pass, mean of 3 after a warm-up) and the mean and max GPU time per frame over 120 frames
starting at t = 300 s (`--time`), from `MTLCommandBuffer` GPU timestamps. It also prints the CPU
time spent encoding each frame. `--config` and `--preset` apply as for snapshots.

## Code layout

Everything is in `Sources/DeepField`:

- `App/`: entry point, app delegate and menu bar, the per-screen wallpaper windows, runtime flags.
- `Config/`: the settings model (`WallpaperConfig`, whose Codable keys are the saved format),
  scene kinds and options, star types, palettes and presets, and `ConfigStore`.
- `Scenes/`: CPU-side scene state: camera, planets, star systems, galaxy kinematics, the event
  schedule, and per-frame parameters for the newer scenes (`SceneParams`, `TidalDisruption`).
- `Rendering/`: `Renderer` (pipelines, bake, frame encoding), `WallpaperView`, and `GPUTypes`
  (uniform layouts mirrored in the shaders).
- `Rendering/Shaders/`: the Metal source as Swift strings, one file per area, joined in order by
  `ShaderSource.full` and compiled at runtime, so the build needs no Metal toolchain.
- `UI/`: the SwiftUI Customize window, one file per tab.
- `Mobile/`: the phone wallpaper export (portrait still, Live Photo pair, Photos library).
- `Dev/`: the command line above (snapshot, benchmark, event list, UI capture).


## App icon

The icon lives in `Design/Icons/AppIcon.png` and `build.sh` turns it into `AppIcon.icns`. The
scripts that generated it and the other candidate icons are in `Design/Icons/` (see its README).
