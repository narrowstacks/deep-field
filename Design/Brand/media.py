"""README media (docs/media) and the website kit's scene gallery, loops and phone stills
(docs/site-assets), all rendered by the app itself through its dev CLI.

    python3 Design/Brand/media.py [--skip-ui]      # needs build/DeepField.app (./build.sh)

Pixel art stays crisp: every image is rendered at its final size (the app upscales its cells
with nearest neighbor), and loops are only ever scaled by whole numbers, nearest neighbor.
"""
import os
import re
import subprocess
import sys

import numpy as np
from PIL import Image

import brand
import dfcli
import loops
import pixelfont

ROOT = dfcli.ROOT
MEDIA = os.path.join(ROOT, "docs/media")
SITE = os.path.join(ROOT, "docs/site-assets")

# Every listed scene, with the moment and any settings used for its stills. `check_scenes` stops
# the run if the app lists a scene that isn't here.
SCENES = [
    ("blackHole", "Black Hole", 60, {}),
    ("tidalDisruption", "Star Meets Black Hole", 60, {}),
    ("wormhole", "Wormhole", 60, {"throat": 5.5}),
    ("binary", "Binary Stars", 60, {}),
    ("trinary", "Trinary Stars", 60, {}),
    ("galaxy", "Galaxy", 60, {}),
    ("pulsar", "Pulsar", 60.5, {}),
    ("comet", "Comet", 60, {}),
    ("stellarSurface", "Star Close-up", 60, {}),
    ("planetaryNebula", "Planetary Nebula", 60, {}),
    ("ringedPlanet", "Ringed Planet", 60, {}),
    ("auroraOrbit", "Aurora from Orbit", 60, {}),
    ("gasGiant", "Gas Giant Storms", 60, {}),
    ("protoplanetaryDisk", "Protoplanetary Disk", 60, {}),
    ("neutronMerger", "Neutron Star Merger", 60, {}),
    ("blackHoleMerger", "Black Hole Merger", 163, {}),    # the pair close, the galaxy behind lensed into a ring
    ("dysonSwarm", "Dyson Swarm", 60, {}),
    ("roguePlanet", "Rogue Planet", 60, {}),
    ("eclipse", "Eclipse", 60, {}),
    ("quasar", "Quasar", 60, {}),
]


def check_scenes():
    """Every scene the app lists (SceneKind, less the parked nebula) needs an entry in SCENES."""
    src = open(os.path.join(ROOT, "Sources/DeepField/Config/SceneKind.swift")).read()
    cases = re.search(r"^\s*case (blackHole,[^\n]*)$", src, re.M).group(1)
    listed = [c.strip() for c in cases.split(",") if c.strip() != "nebula"]
    missing = [c for c in listed if c not in {s[0] for s in SCENES}]
    if missing:
        sys.exit(f"media.py: add these scenes to SCENES (and their README entries): {', '.join(missing)}")

GAP = 8                                     # px between montage tiles (transparent)
LABEL = (232, 236, 244)


def save(im, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if isinstance(im, np.ndarray):
        im = Image.fromarray(im)
    im.save(path, optimize=True)
    print(os.path.relpath(path, ROOT))
    return path


def label(tile, text, cell=2):
    """Pixel-font caption in the tile's bottom-left corner, outlined in black."""
    m = pixelfont.text_mask(text.upper())
    rgba = np.zeros((*m.shape, 4), np.uint8)
    rgba[m] = (*LABEL, 255)
    rgba = brand.outlined(rgba, m)
    im = brand.scale(rgba, cell)
    out = Image.fromarray(tile).convert("RGBA")
    out.alpha_composite(im, (cell * 4, out.height - im.height - cell * 4))
    return np.asarray(out.convert("RGB"))


def montage(tiles, cols):
    h, w, _ = tiles[0].shape
    rows = (len(tiles) + cols - 1) // cols
    out = Image.new("RGBA", (cols * w + (cols - 1) * GAP, rows * h + (rows - 1) * GAP), (0, 0, 0, 0))
    for i, t in enumerate(tiles):
        out.paste(Image.fromarray(t), ((i % cols) * (w + GAP), (i // cols) * (h + GAP)))
    return out


def still(tag, scene, t, size, cell, config=None, demo=None, preset=None):
    p = dfcli.snapshot(os.path.join(dfcli.WORK, "stills", f"{tag}.png"), scene, t, size,
                       {"pixelSize": cell, **(config or {})}, demo, preset=preset)
    return dfcli.load(p)


# ---------- stills ----------

def gallery():
    sheet = []
    for scene, title, t, cfg in SCENES:
        save(still(f"readme-{scene}", scene, t, (960, 600), 3, cfg), os.path.join(MEDIA, "gallery", f"{scene}.png"))
        big = still(f"site-{scene}", scene, t, (1600, 1000), 4, cfg)
        save(big, os.path.join(SITE, "gallery", f"{scene}.png"))
        sheet.append(label(np.asarray(Image.fromarray(big).reduce(2)), title, 3))
    save(montage(sheet, 3), os.path.join(SITE, "gallery", "contact-sheet.png"))


CENTERED = {"phoneFraming": {"zoom": 0.55, "shift": 0.12}}   # black hole centered in a 16:10 tile


def customizations():
    tile = (480, 300)
    types = [("spiral", "Spiral"), ("barred", "Barred spiral"), ("elliptical", "Elliptical"),
             ("irregular", "Irregular"), ("ring", "Ring")]
    tiles = [label(still(f"gal-{g}", "galaxy", 60, tile, 2, {"galaxyType": g}), name) for g, name in types]
    tiles.append(label(still("gal-faceon", "galaxy", 60, tile, 2, {"galaxyView": 70}), "Spiral, face-on"))
    save(montage(tiles, 3), os.path.join(MEDIA, "galaxy-types.png"))

    presets = ["Gargantua", "Ember", "Glacier", "Synthwave", "Amber CRT", "Emerald"]
    tiles = [label(still(f"pal-{p}", "blackHole", 60, tile, 2, CENTERED, preset=p), p) for p in presets]
    save(montage(tiles, 3), os.path.join(MEDIA, "palettes.png"))

    modes = [({}, "Field lines"), ({"pulsarFieldStyle": "magnetar"}, "Magnetar lobes"),
             ({"pulsarRing": True}, "Dust ring"),
             ({"pulsarBeams": "top", "pulsarFieldStyle": "magnetar", "pulsarRing": True}, "One beam, lobes, ring")]
    tiles = [label(still(f"pulsar-{i}", "pulsar", 60.5, tile, 2, c), n) for i, (c, n) in enumerate(modes)]
    save(montage(tiles, 2), os.path.join(MEDIA, "pulsar-modes.png"))

    zooms = [(0.45, "Zoom 0.45"), (1.0, "Zoom 1 (limb)"), (2.5, "Zoom 2.5")]
    tiles = [label(still(f"zoom-{z}", "stellarSurface", 60, tile, 2, {"starZoom": z}), n) for z, n in zooms]
    save(montage(tiles, 3), os.path.join(MEDIA, "star-zoom.png"))

    worlds = [({"eclipseWorld": "rock"}, "Gray rock + teal giant"),
              ({"eclipseWorld": "ice", "eclipseSkyBody": "ringedGiant"}, "Ice + ringed giant"),
              ({"eclipseWorld": "desert", "eclipseSkyBody": "bandedGiant", "eclipseAtmosphere": True}, "Rust desert + air"),
              ({"eclipseWorld": "basalt", "eclipseSkyBody": "rockyMoon"}, "Volcanic basalt + moon")]
    tiles = [label(still(f"eclipse-{i}", "eclipse", 60, tile, 2, c), n) for i, (c, n) in enumerate(worlds)]
    save(montage(tiles, 2), os.path.join(MEDIA, "eclipse-surfaces.png"))

    looks = [({}, "Default"),
             ({"bloom": 2.2, "bloomRadius": 0.05, "bloomThreshold": 0.35, "vignette": 0.8}, "Bloom + vignette"),
             ({"pixelSize": 4, "dither": "bayer4", "levels": 3}, "Bayer 4x4, 3 levels"),
             ({"dither": "none", "levels": 4, "contrast": 1.3}, "Posterized")]
    tiles = []
    for i, (c, n) in enumerate(looks):
        cfg = {"phoneFraming": {"zoom": 0.85, "shift": 0.12}, **c}
        tiles.append(label(still(f"look-{i}", "tidalDisruption", 60, tile, c.get("pixelSize", 2), cfg), n))
    save(montage(tiles, 2), os.path.join(MEDIA, "image-controls.png"))


# ---------- loops ----------

# The README's lead loop: no planets, so the disk has the frame to itself, and a strong but tight
# glow (a high threshold keeps it off the black hole's shadow), a little brighter and richer,
# and no twinkling stars, which flicker distractingly in a short loop.
HERO_LOOK = {"planetCount": 0, "bloom": 1.2, "bloomRadius": 0.025, "bloomThreshold": 0.6,
             "brightness": 1.3, "saturation": 1.5, "blackPoint": 0.02, "twinkles": "off"}

LOOP = (720, 450)      # GIF size; cells of 2 px, so 360x225 cells
FPS = 12


def loop(name, scene, t0, seconds, speed=1.0, config=None, demo=None, blend=1.0, size=LOOP, cell=2,
         site=True, frames=None):
    fr = frames or loops.dissolve_loop(name, scene, t0, seconds, FPS, size, cell, config, demo,
                                       blend=blend, speed=speed)
    loops.gif(fr, FPS, os.path.join(MEDIA, "loops", f"{name}.gif"))
    print(f"docs/media/loops/{name}.gif")
    if site:
        # the website gets the same frames at 2x, nearest neighbor, as H.264
        loops.mp4(fr, FPS, os.path.join(SITE, "loops", f"{name}.mp4"), scale=2)
        big = Image.fromarray(fr[0]).resize((fr[0].shape[1] * 2, fr[0].shape[0] * 2), Image.NEAREST)
        save(big, os.path.join(SITE, "loops", f"{name}-poster.png"))
    return fr


def side_by_side(a, b, la, lb):
    out = []
    for fa, fb in zip(a, b):
        gap = np.zeros((fa.shape[0], GAP, 3), np.uint8)
        out.append(np.concatenate([label(fa, la), gap, label(fb, lb)], axis=1))
    return out


def all_loops():
    loop("black-hole", "blackHole", 60, 4, speed=3, size=(960, 400), cell=3, config=HERO_LOOK)
    loop("star-meets-black-hole", "tidalDisruption", 60, 4, speed=3)
    loop("pulsar", "pulsar", 60, 3, blend=0)             # one 3 s rotation: loops exactly
    loop("galaxy", "galaxy", 60, 4, speed=24, config={"galaxyType": "barred"})
    # dark matter on and off, same moment, both sped up so the outer disk's lag shows
    dm = {"galaxyView": 60, "galaxyRotationMinutes": 3}
    on = loops.dissolve_loop("dm-on", "galaxy", 60, 4, FPS, (480, 400), 2, dm, speed=30)
    off = loops.dissolve_loop("dm-off", "galaxy", 60, 4, FPS, (480, 400), 2, {**dm, "darkMatter": False}, speed=30)
    loop("dark-matter", "", 0, 0, frames=side_by_side(on, off, "Dark matter halo", "Visible mass only"))
    # events, forced with --demo at t = 100 s
    loop("coronal-mass-ejection", "stellarSurface", 99.5, 6, speed=14, demo={10: 100})
    loop("wormhole-emergence", "wormhole", 99.5, 5, speed=9, config={"throat": 5.5}, demo={6: 100})
    loop("comet-tail-disconnect", "comet", 99.5, 5, speed=12, demo={8: 100})
    loop("supernova", "binary", 99.5, 5, speed=10, demo={1: 100}, size=(720, 450))


def black_hole_merger():
    """The black hole merger's README section: its size models and three loops of the merger."""
    # size models (GW190521's settings for the quasar disk)
    gw190521 = {"bbhModel": "agnDisk", "bbhMassRatio": 0.78, "bbhSpin": 0.72, "bbhPrecession": 0.7,
                "bbhView": 50, "bbhEccentric": True}
    models = [("Stellar", 163, {}), ("In a quasar's disk", 190, gw190521),
              ("Intermediate in a cluster", 163, {"bbhModel": "intermediate"}),
              ("Supermassive with a gas disk", 160, {"bbhModel": "supermassive", "bbhView": 62})]
    tiles = [label(still(f"bbh-model-{i}", "blackHoleMerger", t, (720, 450), 2, c), n)
             for i, (n, t, c) in enumerate(models)]
    save(montage(tiles, 2), os.path.join(MEDIA, "black-hole-merger-models.png"))
    # the black hole merger runs through its merger at t = 168 s, in its own slow motion
    loop("black-hole-merger", "blackHoleMerger", 164, 7, config={"bbhTrace": True})
    loop("black-hole-merger-cluster", "blackHoleMerger", 164, 7, config={"bbhModel": "intermediate"})
    loop("black-hole-merger-disk", "blackHoleMerger", 163, 7, config={"bbhModel": "supermassive", "bbhView": 62})


# ---------- phone ----------

PHONES = [("blackHole", {}), ("galaxy", {}), ("pulsar", {}), ("stellarSurface", {})]


def phones():
    outs = []
    for scene, _ in PHONES:
        d = os.path.join(dfcli.WORK, "phone", scene)
        subprocess.run([dfcli.BIN, "--mobile-export", d, "--device", "17-pro-max", "--scene", scene, "--defaults"],
                       check=True, stdout=subprocess.DEVNULL)
        png = [f for f in os.listdir(d) if f.endswith(".png")][0]
        im = Image.open(os.path.join(d, png)).convert("RGB")
        save(im, os.path.join(SITE, "phone", f"{scene}.png"))
        outs.append(im)
    # mockup: each screen in a rounded black bezel, downscaled with a box filter
    w = 300
    shots = []
    for im in outs:
        h = round(im.height * w / im.width)
        screen = brand.rounded(im.resize((w, h), Image.BOX), 34)
        frame = Image.new("RGBA", (w + 16, h + 16), (0, 0, 0, 0))
        frame.alpha_composite(brand.rounded(Image.new("RGB", frame.size, (22, 24, 30)), 42))
        frame.alpha_composite(screen, (8, 8))
        shots.append(frame)
    gap = 28
    sheet = Image.new("RGBA", (sum(s.width for s in shots) + gap * (len(shots) - 1), shots[0].height), (0, 0, 0, 0))
    x = 0
    for s in shots:
        sheet.alpha_composite(s, (x, 0))
        x += s.width + gap
    save(sheet, os.path.join(MEDIA, "phones.png"))
    save(sheet, os.path.join(SITE, "phone", "phone-mockups.png"))


# ---------- Customize window ----------

UI = [(0, "galaxy", "ui-scene"), (2, "blackHole", "ui-image"), (4, "pulsar", "ui-phone"), (1, "wormhole", "ui-sky")]


def ui():
    """Launches the app per capture (with --defaults it shows and saves nothing of yours)."""
    for tab, scene, name in UI:
        out = os.path.join(MEDIA, f"{name}.png")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run([dfcli.BIN, "--capture-ui", out, "--defaults", "-captureTab", str(tab), "-captureScene", scene],
                       check=True)
        Image.open(out).save(out, optimize=True)
        print(os.path.relpath(out, ROOT))


def main():
    check_scenes()
    gallery()
    customizations()
    phones()
    all_loops()
    black_hole_merger()
    if "--skip-ui" not in sys.argv:
        ui()


if __name__ == "__main__":
    main()
