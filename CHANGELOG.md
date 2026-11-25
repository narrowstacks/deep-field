# Changelog

All notable changes to Deep Field. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

- Presets and exported preset files now leave out Live Earth's place (which can be your Mac's location) unless you choose to include it: tick the box when saving or exporting, use Include Live Earth's Place in the Presets menu for presets you already have, or add `--with-place` on the command line. Files exported before this update still contain it.
- Live Earth asks for your Mac's location whenever following it is turned on, including by a preset or the command line.
- Saving a preset suggests an unused name and asks before replacing one, and renaming can't give two presets the same name.
- Welcome guide: the lock screen and login choices now wait for the last button, so Not Now leaves them alone. Opened with Deep Field already on the desktop, it says that changes show there as you make them.
- Welcome guide: turning a look off, or Undo All, goes back to your own settings instead of the defaults.
- Fixed a crash when switching scenes after loading a damaged preset.
- With the animation paused, scheduled switches and `--fade` now cut straight to the new scene instead of leaving the old one up, and pausing partway through a transition ends on the new scene.
- Schedule: editing a rotation (its looks, their order, the interval or shuffle) no longer switches the wallpaper early, and turning a rotation on starts at its first look with a full interval.

## [0.4.8] - 2026-11-18

- A `deepfield` command for the terminal: switch scenes and presets, change any setting of the running wallpaper, trigger events, control the schedule, and render stills, videos, time-lapses, GIFs and frame sequences. Install it with `DeepField.app/Contents/MacOS/DeepField install`, and see `deepfield help`.
- Eclipse: the sunlight no longer swells into a lumpy, hard-edged blob as totality nears, and its glare fades off gradually. Baily's beads now appear only in the last moments, and prominences only show once the sun is almost covered.

## [0.4.7] - 2026-11-17

- Five new dither patterns under Image: Bayer 2×2, Blue noise, Halftone dots, Diagonal lines and White noise.
- Color levels in Customize now go up to 32 and 64. The welcome guide's Smooth look uses 64, which you couldn't pick again in Customize after changing it.

## [0.4.6] - 2026-11-16

- Live Earth: a new Aurora speed slider sets how fast the aurora ripples and drifts. It now moves at half its old pace by default.
- Fixed bloom at large radii breaking into rings, stripes and patches around bright edges such as Earth's limb.
- Eclipse: the ground keeps the same craters and boulders at every pixel size, instead of losing most of them at larger sizes.
- Aurora from Orbit: substorms no longer make the curtains race and flicker; they now speed up smoothly. The Activity slider is now called Speed, goes lower, and new setups start at a calmer pace.
- Optionally show Deep Field in the Dock and the app switcher while the Customize window is open, with a full app menu (turn it on under System in Customize). Clicking the Dock icon brings Customize back.
- Copy, paste, undo and the other standard shortcuts now work in Customize's text fields.

## [0.4.5] - 2026-11-16

- New scene: Live Earth. The whole Earth as it is right now, seen from high above a place you choose, which stays in the middle of the view. Sunlight, seasons and the day-night line are real, with city lights on the night side and the sun's glint on the oceans.
- Pick the place by latitude and longitude, or let it follow your Mac's location.
- The Moon is where it really is, in its real phase, and lights the night side by its phase. Eclipses happen when they really do: the Moon's shadow crosses Earth in a solar eclipse, and the Moon turns red in Earth's shadow in a lunar one.
- The stars behind Earth are the real night sky (about 9,000 stars in their own colors, and the Milky Way), turned to where they are at that moment.
- Optional live clouds from weather satellites and NOAA's aurora forecast, updated while the scene shows. The last ones downloaded are kept, so the view still works offline.
- The planets are in the sky too, where they really are and as bright as they really look. Keep them at true size, as points of light, or enlarge them to see their disks, phases, Jupiter's bands and Saturn's rings, and turn on labels to name them.
- Freeze Live Earth on a past date and it shows that day's real clouds, from weather satellite records going back to 1980. They're downloaded once and kept.
- The sun's disk and glare can be hidden while it's night at your place (its light still reaches Earth), and the clock can be frozen at any date and time.

## [0.4.1] - 2026-11-15

- Change scenes on a schedule: rotate through your presets and scenes every few minutes to once a day (in order or shuffled), or switch at set times on the days you choose. Set it up in the new Schedule section of Customize, and turn it on or skip ahead from the menu bar.
- Each scheduled switch has a transition: Dissolve, Crossfade, Pan, Drift Away (the old scene's objects float off into the distance), Warp, Black Hole (a black hole sweeps across, bending one scene into the next), or Random.
- Aurora from Orbit now shows the real Earth at night: actual city lights, coastlines and snow, turning slowly beneath you from Europe across North America and Asia.
- The tops of the aurora curtains now fade softly into space instead of breaking up into a sharp, grainy edge.
- Aurora from Orbit uses about a quarter of the GPU time it did, with the same look.

## [0.4.0] - 2026-11-15

- New scene: Black Hole Merger. Two black holes spiral together, bending the starlight behind them into arcs and rings, and merge into one larger hole that rings down in a last burst of gravitational waves.
- Load a real detection (GW150914, GW170814, GW190412, GW190521, GW190814, GW231123 or GW250114) to use its masses, spins and viewing angle, or set mass ratio, spin and precession yourself.
- Choose the black holes' size: stellar pairs in empty space or inside a quasar's gas disk (where the remnant sets off a flare), intermediate ones inside a dense star cluster, or supermassive ones in a gas disk, with streams feeding each hole and jets that change direction after the merger.
- A distant galaxy behind the pair is bent into a ring that breaks into arcs as the holes move.
- Options for an eccentric orbit that dives in and whirls round with a burst of waves at each pass, a recoil kick that sends the remnant drifting off, and a hierarchical chain where each remnant takes on the next companion.
- Turn on Strain trace to see the waves drawn along the bottom as a detector records them: the rising chirp, the merger and the ringdown.
- New EHT color look, after the Event Horizon Telescope's images.
- The shadows stretch toward each other and join through a neck, and the new hole starts as a spinning peanut that rounds out. Ringdown slow motion slows the merger so you can watch it, and Speed sets how fast the whole scene runs.
- Each scene has a Reset button that puts its settings and colors back to their defaults.
- Give a scene its own image settings (exposure, bloom, pixel size and the rest) with Separate settings for this scene in the Image section. Other scenes keep the shared ones.
- Star field in the Sky section rearranges the background sky. Type a seed to get the same sky back, or press Randomize.
- Twinkling stars now have brightness and speed controls.
- Focus filters: in System Settings > Focus, have a Focus switch Deep Field to one of your presets or a scene, and switch back when it ends.
- Shortcuts actions to apply a preset or set the scene.
- Fixed: on macOS 14 and 15 the wallpaper showed only on the Space where Deep Field started. It now shows on every Space.
- Protoplanetary Disk: with low flaring, the star no longer shows dark speckles.
- Eclipse: a planet placed in front of the sun now blocks its light and glare, and the corona comes out around it.
- Eclipse: the ground looks more natural on every world. Craters no longer overlap, big craters are shallower, and boulders lie scattered around them. Rock has broad swells and lighter and darker regions, ice has softer frost glints, dunes are gentler and patchier, and basalt has ropy folds.
- Dragging Tilt (and the galaxy's viewing angle) now turns the view smoothly. Before, the scene drifted up or down, then jumped to the new angle.

## [0.3.0] - 2026-11-15

- Every scene with its own colors now has one-click color presets, shown as swatches like the black hole's. Choosing a black hole palette no longer changes the galaxy scene's colors.
- Making the Customize window bigger now makes the preview bigger too, with more scenes per row in the gallery. The preview costs no more to draw at a larger size.
- At 1:1 preview scale, drag the preview to look around the whole screen.

## [0.2.1] - 2026-11-15

- The scene gallery in the Customize window scrolls, so every scene can be reached. Before, the last few were cut off with no way to get to them.
- The Customize window can be resized. Make it taller to see more scenes at once, or wider for more room for settings. It remembers its size and position.

## [0.2.0] - 2026-11-15

- Ten new scenes: Planetary Nebula, Ringed Planet, Aurora from Orbit, Gas Giant Storms, Protoplanetary Disk, Neutron Star Merger, Dyson Swarm, Rogue Planet, Eclipse and Quasar, each with its own settings, colors and occasional events.
- Eclipse lets you choose the world you stand on and the planet in the sky, give it an atmosphere, and hold the eclipse at totality to watch the corona and eruptions.
- A welcome guide on first launch: pick a scene and try a few looks on a large preview. Your desktop only changes when you choose Set as Wallpaper.
- Presets: save your customizations, switch between them from the menu bar, and share them as `.deepfield` files.
- Show on Desktop in the menu bar turns the wallpaper off and on without quitting.
- A light bloom is on by default, and twinkling stars no longer throw large square glows when bloom is on.

## [0.1.0] - 2026-11-15

First release.

- Animated, pixel-dithered space wallpapers for macOS 14 and later, rendered on the GPU and paused whenever the desktop is covered, the display sleeps, or the screen is locked.
- Nine scenes: Black Hole (a lensed accretion disk), Star Meets Black Hole, Wormhole, Binary Stars, Trinary Stars, Galaxy (spiral, barred, elliptical, ring and irregular, with or without a dark matter halo), Pulsar, Comet and Star Close-up.
- Rare events in the background sky: twinkles, supernovae with light echoes, passing comets, and per-scene events like coronal mass ejections, comet outbursts and wormhole flares.
- Planets that orbit slowly and bend around the black hole and wormhole.
- A Customize window with a live preview: per-scene settings and colors, palettes, sky and event frequency, bloom, exposure and contrast, pixel size, color levels and dither pattern.
- A matching still for the lock and login screens.
- Phone wallpaper export: a portrait still or a Live Photo, sized for current iPhones.
- Automatic updates.
