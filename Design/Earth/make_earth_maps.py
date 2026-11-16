#!/usr/bin/env python3
"""Make the Earth maps for the Aurora from Orbit and Live Earth scenes.

Sources (all public domain NASA imagery):
- Black Marble 2016 night composite (Suomi NPP VIIRS, 13500x6750):
  https://assets.science.nasa.gov/content/dam/science/esd/eo/images/imagerecords/144000/144898/BlackMarble_2016_3km.jpg
- Blue Marble Next Generation, January and July 2004 (5400x2700, no clouds):
  https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-base/january/world.200401.3x5400x2700.jpg
  https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-base/july/world.200407.3x5400x2700.jpg
- The Moon, LRO color mosaic (NASA SVS CGI Moon Kit, 1024x512):
  https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_poles_1k.jpg

- The sky: the Yale Bright Star Catalog, 5th edition (public domain, ~9100 stars to magnitude 6.5):
  http://tdc-www.harvard.edu/catalogs/bsc5.dat.gz (gunzipped to bsc5.dat)
  and NASA SVS's Deep Star Maps 2020 for the Milky Way (celestial coordinates, 1024x512):
  https://svs.gsfc.nasa.gov/vis/a000000/a004800/a004851/starmap_2020_4k_print.jpg

Offline fallbacks for Live Earth's live layers, used until the app has fetched its own:
- clouds: https://clouds.matteason.co.uk/images/2048x1024/clouds.jpg
- aurora: https://services.swpc.noaa.gov/json/ovation_aurora_latest.json (NOAA SWPC OVATION)

    python3 Design/Earth/make_earth_maps.py <folder with the files above>

writes, into Resources/Earth (every map is equirectangular, whole globe, column 0 at 180 W,
row 0 at 90 N, except the aurora grid, which keeps NOAA's layout, see aurora_fallback):
- night-lights.png: 8192x4096 gray, city light (linear light, square-root encoded)
- night-ground.png: 2048x1024 gray, the dim ground under them (land vs sea, snow)
- day-jan.jpg, day-jul.jpg: 2880x1440 color, the cloud-free surface in each season
- water.png: 2048x1024 gray, 255 over open water (for the sun's glint)
- moon.png: 1024x512 gray, the Moon's albedo
- stars.bin: the catalog, per star four little-endian float32s: right ascension and declination
  (J2000, radians), V magnitude, B-V color index
- milkyway.jpg: 1024x512 color, the Milky Way's glow with the stars filtered out; column 0 at
  right ascension 0, increasing eastward (to the right), row 0 at declination +90
- clouds-fallback.jpg: 2048x1024 gray
- aurora-fallback.png: 360x181 gray
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

NIGHT_W = 8192
GROUND_SCALE = 4
DAY_W = 2880


def linear(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def resize(a, w, h):
    # area average in linear light
    return np.asarray(Image.fromarray(a.astype(np.float32), mode="F").resize((w, h), Image.BOX))


def save_sqrt(a, path):
    # square-root encoding keeps the dim towns that 8-bit linear would round away
    Image.fromarray((np.sqrt(np.clip(a, 0, 1)) * 255 + 0.5).astype(np.uint8), mode="L").save(path, optimize=True)


def night(src, out):
    src = np.asarray(Image.open(src).convert("RGB")).astype(np.float32)
    r, b = linear(src[..., 0]), linear(src[..., 2])
    # Black Marble lays the lights (warm white, red about equal to blue) over a dim blue-tinted
    # ground (blue about three times red). Red minus half of blue leaves the lights; blue minus
    # red leaves the ground and zeroes out under the cities.
    lights = np.clip((r - 0.5 * b) / 0.5, 0, 1)
    ground = np.clip((b - r) / 0.12, 0, 1)
    save_sqrt(resize(lights, NIGHT_W, NIGHT_W // 2), out / "night-lights.png")
    save_sqrt(resize(ground, NIGHT_W // GROUND_SCALE, NIGHT_W // 2 // GROUND_SCALE), out / "night-ground.png")


def day(src, path):
    im = Image.open(src).convert("RGB").resize((DAY_W, DAY_W // 2), Image.LANCZOS)
    im.save(path, quality=88, optimize=True)
    return np.asarray(Image.open(src).convert("RGB")).astype(np.float32)


def water(day_rgb, path):
    # Blue Marble paints open water one flat dark blue (2, 5, 20); anything near it is sea or lake
    d = np.abs(day_rgb - np.array([2, 5, 20], np.float32)).sum(axis=2)
    mask = (d < 18).astype(np.float32)
    Image.fromarray((resize(mask, 2048, 1024) * 255 + 0.5).astype(np.uint8), mode="L").save(path, optimize=True)


def moon(src, path):
    Image.open(src).convert("L").save(path, optimize=True)


def stars(src, path):
    rows = []
    for line in Path(src).read_text(errors="replace").splitlines():
        if len(line) < 107 or not line[75:77].strip() or not line[102:107].strip():
            continue  # a few entries (novae, objects no longer counted as stars) have no position
        ra = (int(line[75:77]) + int(line[77:79]) / 60 + float(line[79:83]) / 3600) * 15
        dec = int(line[84:86]) + int(line[86:88]) / 60 + int(line[88:90]) / 3600
        if line[83] == "-":
            dec = -dec
        bv = line[109:114].strip()
        rows.append((np.radians(ra), np.radians(dec), float(line[102:107]), float(bv) if bv else 0.6))
    np.asarray(rows, "<f4").tofile(path)
    print(len(rows), "stars")


def milky_way(src, path):
    from PIL import ImageFilter
    im = Image.open(src).convert("RGB")
    # a median filter leaves the diffuse glow and removes the stars, which the catalog draws sharply
    im = im.filter(ImageFilter.MedianFilter(7))
    a = np.asarray(im)
    # NASA's map has right ascension 0 in the middle, increasing to the left (the sky seen from
    # inside); flip and roll it so column 0 is RA 0 and RA increases to the right
    w = a.shape[1]
    a = np.roll(a[:, ::-1], w // 2 + 1, axis=1)
    Image.fromarray(a).save(path, quality=90, optimize=True)


def clouds_fallback(src, path):
    # the live map is centered on 0 degrees like ours, so it only needs to be gray
    Image.open(src).convert("L").resize((2048, 1024), Image.BOX).save(path, quality=85, optimize=True)


def aurora_fallback(src, path):
    """NOAA's grid as an image: column i is longitude i degrees east, row j latitude 90 - j,
    value the chance of seeing aurora overhead (percent, scaled to 0..255)."""
    data = json.loads(Path(src).read_text())
    grid = np.zeros((181, 360), np.float32)
    for lon, lat, v in data["coordinates"]:
        grid[90 - int(lat), int(lon) % 360] = v
    Image.fromarray(np.clip(grid * 2.55 + 0.5, 0, 255).astype(np.uint8), mode="L").save(path, optimize=True)


def main():
    Image.MAX_IMAGE_PIXELS = None
    src = Path(sys.argv[1])
    out = Path(__file__).resolve().parents[2] / "Resources" / "Earth"
    out.mkdir(parents=True, exist_ok=True)
    night(src / "BlackMarble_2016_3km.jpg", out)
    day(src / "world.200401.3x5400x2700.jpg", out / "day-jan.jpg")
    july = day(src / "world.200407.3x5400x2700.jpg", out / "day-jul.jpg")
    water(july, out / "water.png")
    moon(src / "lroc_color_poles_1k.jpg", out / "moon.png")
    stars(src / "bsc5.dat", out / "stars.bin")
    milky_way(src / "starmap_2020_4k_print.jpg", out / "milkyway.jpg")
    clouds_fallback(src / "clouds.jpg", out / "clouds-fallback.jpg")
    aurora_fallback(src / "ovation.json", out / "aurora-fallback.png")
    for f in sorted(out.iterdir()):
        print(f, f.stat().st_size)


if __name__ == "__main__":
    main()
