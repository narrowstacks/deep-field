# Developing Deep Field

## Build

You need the Swift toolchain from Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/narrowstacks/deep-field.git && cd deep-field
./build.sh && open build/DeepField.app
```

`build.sh` builds a release binary for this Mac and wraps it into `build/DeepField.app`
(ad-hoc signed). `UNIVERSAL=1` adds Intel, and `SIGNING_IDENTITY` signs it for distribution.

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
- `UI/`: the SwiftUI Customize window, one file per section, plus the stage, gallery and theme.
- `Mobile/`: the phone wallpaper export (portrait still, Live Photo pair, Photos library).
- `Dev/`: the command line below (snapshot, benchmark, event list, UI capture).

An older nebula scene (pillars, dark clouds) is in the code but hidden from the scene list; see
`SceneKind.isListed`.

## How it renders

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
- **Low resolution on purpose.** It renders at 1/3 of screen resolution by default, and the
  compositor scales it up with nearest-neighbor filtering, so the GPU shades about 1/9 of the
  pixels.
- **Low frame rate.** 24 fps by default, capped at 12 in Low Power Mode and at 8 under thermal
  pressure.
- **Stops when nobody can see it.** The display link pauses when the wallpaper window is fully
  covered (`NSWindow.occlusionState`), when the displays sleep, and when you switch users.
- **Events are scheduled on the CPU** from a seeded hash per time slot, so there is no
  simulation state.
- **Image controls** (exposure, contrast, saturation, highlight rolloff, black point, vignette
  and bloom) work on the scene's light before it's tone mapped and dithered, so the result stays
  dithered on the wallpaper, the lock screen still and phone exports alike. Bloom is a bright
  pass and blur at a quarter of the shaded size; at 0 those passes don't run.
- **Picked colors.** A picked color is what that part shows where it's typically lit:
  `Config/PickedColor.swift` runs the tone map, saturation and gamma backwards from the pick, at
  each element's measured typical brightness. The background sky's colors and the galaxy's dust
  stay tints.

### Galaxy rotation and dark matter

Each star orbits at its own angular speed, ω(r) = v(r) / r, taken from a rotation curve. With a
dark matter halo (the default), v(r) rises and then stays flat out to the edge, as observed in
real galaxies. With visible mass only, v(r) peaks near the center and falls off like v ∝ 1/√r,
so the outer disk lags.

Spiral arms and bars are density waves that rotate at one pattern speed while stars drift
through them, so the arms don't wind up. Across an arm you see the order density-wave theory
predicts: dust lane on the inside edge, then pink star-forming regions, then young blue stars.
Dwarf irregulars turn almost like a solid body, matching their rising rotation curves.

### Phone Live Photos

A Live Photo export is a 3-second loop with events off and planets and star orbits held still,
at 2x the wallpaper's speed by default. The pulsar's loop is a whole number of turns; elsewhere
the last second dissolves, cell by cell along a Bayer threshold, into the frames before the
start, so it loops without a jump. It's saved as a HEIC still plus a HEVC QuickTime movie that
share a content identifier (the still's Apple maker note key 17, the movie's
`com.apple.quicktime.content.identifier`, and a `still-image-time` metadata track at the middle
frame).

### Lock screen still

Deep Field keeps a still of the current scene as each screen's desktop picture. It re-renders
when the scene's look or your displays change, leaves alone a screen whose picture you've changed
since, and puts your original pictures back when you turn the option off.

## Command line

```bash
.build/release/DeepField --snapshot out.png --time 444 [--size 3440x1440] [--scene wormhole] \
    [--preset Synthwave] [--config '{"galaxyType": "barred", "darkMatter": false}'] [--no-events] \
    [--demo 1:440]                                            # force event kind 1 to start at t=440 s
# --preset takes a palette preset (Synthwave) or a color preset of the chosen scene
# (--scene gasGiant --preset Neptune); see ColorPreset.all(for:) in Config/ColorPresets.swift.
.build/release/DeepField --benchmark [--scene galaxy] [--size 3440x1440] [--frames 120]
.build/release/DeepField --list-events 60 --scene wormhole   # when events fire (seed 1)
.build/release/DeepField --mobile-export outdir [--device 17-pro-max|1179x2556] [--live] [--smooth] \
    [--phone-pixel 4] [--zoom 1.2] [--shift 0.05] [--speed 2] [--scene comet] [--defaults]
.build/release/DeepField --check-live still.HEIC movie.MOV   # pairing metadata, loads as a Live Photo?
build/DeepField.app/Contents/MacOS/DeepField --customize   # open the Customize window at launch
build/DeepField.app/Contents/MacOS/DeepField --check-picker outdir -captureTab 0   # drive the color wells, check the preview follows
build/DeepField.app/Contents/MacOS/DeepField --capture-ui out.png -captureTab N -captureScene name [--defaults]   # image of the window (N: 0 Scene, 1 Sky, 2 Image, 3 System, 4 Phone)
defaults write com.narrowstacks.DeepField debug -bool true     # log bake times, fps, pause/resume
.build/release/DeepField --preset-roundtrip out.deepfield [--scene ...] [--config ...]   # write a preset file, read it back, compare
.build/release/DeepField --preset-check file.deepfield         # load a preset file the way Import does
build/DeepField.app/Contents/MacOS/DeepField --welcome          # show the first-launch guide
build/DeepField.app/Contents/MacOS/DeepField --capture-welcome out.png -welcomeStep N [--defaults]   # image of guide step N (0 to 3)
```

A `.deepfield` preset is JSON: `{"format": "deep-field-preset", "version": 1, "name": ..., "config": {...}}`,
where `config` holds the same keys as the saved settings. It's read with the same lenient decoder,
so missing or unknown keys fall back to defaults.

`--defaults` starts from the default settings instead of your saved ones (for `--capture-ui`
too, which never saves or touches desktop pictures). `--mobile-export` always writes the
portrait still as `<name>.png`; with `--live` it also writes the Live Photo pair, prints its
pairing metadata, checks that PhotoKit loads it as a Live Photo (without touching the library),
and writes `<name> preview.mp4`, the loop played three times.

Snapshots are deterministic, so comparing `md5` of a set of them before and after a change shows
whether the output moved. Scene events keep firing with `--no-events` (that flag only turns off
the shared sky events), so check `--list-events` when you want a calm frame. Event kind ids for
`--demo` are listed in `Scenes/Events.swift`.

`--benchmark` renders every listed scene (or just `--scene`, hidden ones included) offscreen at
3440x1440 and the configured pixel size. Per scene it prints the GPU time of a bake (ray trace
plus sky pass, mean of 3 after a warm-up), the mean and max GPU time per frame over 120 frames
starting at t = 300 s (`--time`), and the CPU time spent encoding each frame.

## Releasing

The version lives in `VERSION`, and each release has a section in `CHANGELOG.md`. To ship:

1. Set `VERSION` (for example `0.2.0`), move the `Unreleased` notes into a `## [0.2.0]` section, and commit.
2. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`.

The [Release workflow](../.github/workflows/release.yml) then builds a universal app on the
self-hosted Mac runner, signs it with the Developer ID certificate, packages and notarizes the
DMG, signs a Sparkle appcast, and publishes both to a GitHub release. Installed copies pick up
the new version from `releases/latest/download/appcast.xml`. A tag with a suffix
(`v0.2.0-beta.1`) becomes a prerelease, which the update feed skips.
[CI](../.github/workflows/ci.yml) builds every push and pull request on GitHub-hosted runners.

Secrets the release needs: `APPLE_DEVELOPER_ID_P12_B64` and `APPLE_DEVELOPER_ID_P12_PASSWORD`
(the Developer ID Application certificate), `APPLE_NOTARY_API_KEY_B64`, `APPLE_NOTARY_API_KEY_ID`
and `APPLE_NOTARY_API_ISSUER_ID` (an App Store Connect API key for notarization), and
`SPARKLE_ED_PRIVATE_KEY` (the update signing key; its public half is `SUPublicEDKey` in `build.sh`).

## App icon, logo and media

The icon lives in `Design/Icons/AppIcon.png`, and `build.sh` turns it into `AppIcon.icns`. The
scripts that generated it and the other candidate icons are in `Design/Icons/` (see its README).

The wordmark, banner and every image and loop in the README are rendered by the app itself and
regenerated with one script (needs Python 3 with numpy and Pillow, and ffmpeg):

```bash
Design/Brand/make_media.sh
```

See [`Design/Brand/README.md`](../Design/Brand/README.md) for what it makes and
[`site-assets/README.md`](site-assets/README.md) for the website kit (heroes, social cards,
favicons, gallery, MP4 loops, copy). Longer, higher quality videos belong on a release as
attachments rather than in the repo.
