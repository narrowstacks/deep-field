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
- **Star Meets Black Hole**: a tidal disruption. A star falls in on a near-parabolic orbit, is
  torn into a stream at closest approach, and its debris forms a new disk that flares and fades.
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
    [--preset Synthwave] [--config '{"galaxyType": "barred", "darkMatter": false}'] [--no-events]
.build/release/DeepField --list-events 60 --scene wormhole   # when events fire (seed 1)
build/DeepField.app/Contents/MacOS/DeepField --customize   # open the Customize window at launch
defaults write local.deepfield.wallpaper debug -bool true     # log bake times, fps, pause/resume
```

Settings live in `Config.swift`. Scene geometry, planets and star systems are in
`SceneModel.swift`, galaxy kinematics in `Galaxy.swift`, events in `Events.swift`, and all GPU
code in `Shaders.swift`.
