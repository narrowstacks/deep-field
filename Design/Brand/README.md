# Brand and media

Everything here is generated, either drawn in code or rendered by the app through its dev CLI,
so it can be rebuilt after any change to the scenes, the icon or the copy:

```bash
Design/Brand/make_media.sh            # builds the app first if build/DeepField.app is missing
Design/Brand/make_media.sh --skip-ui  # skips the Customize window captures (they open a window)
```

Requires Python 3 with `numpy` and `Pillow`, and `ffmpeg`. A full run takes under a minute.
Intermediate renders go to `Design/Brand/output/` (git-ignored).

Every render passes `--defaults` plus an explicit config patch, so the results don't depend on
your saved settings, and nothing writes to them (`--capture-ui --defaults` turns saving off and
leaves desktop pictures alone).

## Files

| File | Makes |
|---|---|
| `make_media.sh` | Runs both scripts below. |
| `brand.py` | Wordmark (PNG and SVG, dark and light), logo lockup, README banner, website heroes, Open Graph and Twitter cards, favicon set. |
| `media.py` | README gallery, loops (GIF), customization montages, phone mockups, Customize window shots; the website gallery, MP4 loops with posters, and phone stills. |
| `pixelfont.py` | The two pixel fonts (below). |
| `loops.py` | Seamless loops from snapshots, GIF and MP4 encoding. |
| `dfcli.py` | Calls the app's `--snapshot` with `--defaults`, in parallel. |

## Wordmark

"DEEP FIELD" is set in a 6x10 display font drawn in `pixelfont.py` (two-cell stems, only the
letters it needs). Taglines and labels use a 5x7 font from the same file. No font files are
used, so there is nothing to license. Each font cell is split into 2x2 dots and colored with
an ordered (Bayer 8x8) dither between the icon's own ramps (`Design/Icons/make.py`): warm on
DEEP, cool on FIELD, bright at the top and deeper toward the baseline, matching the photon
ring icon's warm and cool halves.

- `wordmark-dark`: bright ramps, for dark backgrounds.
- `wordmark-light`: deep ramps, for light backgrounds.

The SVG versions are pixel grids (one `rect` per run, `shape-rendering="crispEdges"`), so they
scale to any size without blurring.

## Banner and heroes

A black hole render from the app, its center placed right of the middle, fades to black toward
the left edge cell by cell along a Bayer threshold, so the fade is dithered like the scene
itself. The icon, wordmark and tagline sit on the black side, with a one-dot black outline so
they stay readable where the disk reaches them. The README banner sets the wordmark and tagline
in plain white, a size larger, and has rounded, transparent corners, so it sits well on GitHub's light and dark themes. The taller heroes and social cards
pull the camera back with the app's phone framing zoom.

## Loops

`loops.py` renders the frames of a loop plus one second before its start. Over the last second
the loop dissolves into those earlier frames, cell by cell along a Bayer threshold (as the
app's Live Photo export does), so it wraps without a jump. Every output pixel is still one of
the app's own colors (at 5 levels, at most 125), so the GIF palette is exact and needs no
extra dithering. The pulsar loop is one whole rotation and needs no dissolve. Event loops force
an event with `--demo` and run the clock faster (the speed is in each caption).
