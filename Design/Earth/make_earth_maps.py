#!/usr/bin/env python3
"""Make the Aurora scene's Earth maps from NASA's Black Marble 2016 night composite.

Source (public domain, NASA Earth Observatory, Suomi NPP VIIRS):
https://assets.science.nasa.gov/content/dam/science/esd/eo/images/imagerecords/144000/144898/BlackMarble_2016_3km.jpg
(13500x6750, equirectangular, 3 km per pixel)

    python3 Design/Earth/make_earth_maps.py BlackMarble_2016_3km.jpg

writes, into Resources/Earth:
- night-lights.png: 8192 x 2368 grayscale, city light (linear light, square-root encoded)
- night-ground.png: 2048 x 592 grayscale, the dim ground under them (land vs sea, snow)

Both cover all longitudes (column 0 at 180 W) and latitudes 90 N down to MAP_SOUTH, with square
pixels; the shader reads that range from the same constants (AU_MAP_SOUTH in ShaderAurora.swift).
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

WIDTH, ROWS = 8192, 2368
MAP_SOUTH = 90.0 - ROWS * 360.0 / WIDTH      # -14.0625
GROUND_SCALE = 4


def linear(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def resize(a, w, h):
    # area average in linear light
    return np.asarray(Image.fromarray(a.astype(np.float32), mode="F").resize((w, h), Image.BOX))


def save(a, path):
    # square-root encoding keeps the dim towns that 8-bit linear would round away
    Image.fromarray((np.sqrt(np.clip(a, 0, 1)) * 255 + 0.5).astype(np.uint8), mode="L").save(path, optimize=True)


def main():
    Image.MAX_IMAGE_PIXELS = None
    src = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(np.float32)
    h, w, _ = src.shape
    rows = int(round((90.0 - MAP_SOUTH) / 180.0 * h))
    src = src[:rows]
    r, b = linear(src[..., 0]), linear(src[..., 2])
    # Black Marble lays the lights (warm white, red about equal to blue) over a dim blue-tinted
    # ground (blue about three times red). Red minus half of blue leaves the lights; blue minus
    # red leaves the ground and zeroes out under the cities.
    lights = np.clip((r - 0.5 * b) / 0.5, 0, 1)
    ground = np.clip((b - r) / 0.12, 0, 1)
    out = Path(__file__).resolve().parents[2] / "Resources" / "Earth"
    out.mkdir(parents=True, exist_ok=True)
    save(resize(lights, WIDTH, ROWS), out / "night-lights.png")
    save(resize(ground, WIDTH // GROUND_SCALE, ROWS // GROUND_SCALE), out / "night-ground.png")
    for f in sorted(out.iterdir()):
        print(f, f.stat().st_size)


if __name__ == "__main__":
    main()
