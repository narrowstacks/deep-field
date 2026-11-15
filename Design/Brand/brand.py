"""Deep Field brand art: wordmark, logo lockup, README banner, website heroes, social cards
and favicons. Scene backgrounds come from the app (dfcli); everything else is drawn here.

    python3 Design/Brand/brand.py        # needs build/DeepField.app (./build.sh)
"""
import os

import numpy as np
from PIL import Image

import dfcli
import pixelfont

ROOT = dfcli.ROOT
ICON = os.path.join(ROOT, "Design/Icons/AppIcon.png")
MEDIA = os.path.join(ROOT, "docs/media")
SITE = os.path.join(ROOT, "docs/site-assets")
TAGLINE = "ANIMATED SPACE WALLPAPERS FOR MACOS"


def hexrgb(h):
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.uint8)


def bayer(n):
    m = np.array([[0]])
    while m.shape[0] < n:
        m = np.block([[4 * m, 4 * m + 2], [4 * m + 3, 4 * m + 1]])
    return (m + 0.5) / m.size


B8 = bayer(8)

# The icon's ramps (Design/Icons/make.py), brightest first.
RAMPS = {
    "dark": (["fff1d6", "ffb347", "f2700f"], ["ffffff", "b6e6ff", "4aa6ff"]),    # for dark backgrounds
    "light": (["f2700f", "9a3208", "3a0f04"], ["4aa6ff", "1f4fd8", "0b1a4a"]),   # for light backgrounds
}
TAG_COLOR = {"dark": hexrgb("b9c3d6"), "light": hexrgb("3b4256")}


# ---------- wordmark ----------

def wordmark_dots(theme="dark", sub=2):
    """The wordmark as a dot grid: (rgba uint8, mask). Each font cell is sub x sub dots, colored
    by ordered dither: warm on DEEP, cool on FIELD, bright at the top fading down."""
    m = pixelfont.wordmark_mask().repeat(sub, 0).repeat(sub, 1)
    H, W = m.shape
    yy, xx = np.mgrid[0:H, 0:W]
    t1 = B8[yy % 8, xx % 8]
    t2 = B8[(yy + 3) % 8, (xx + 5) % 8]
    hue = np.clip((xx / (W - 1) - 0.36) / 0.3, 0, 1)
    cool = hue > t2
    v = (yy + 0.5) / H * 2.0                     # 0..2 down the letters -> ramp steps
    step = np.clip(np.floor(v) + ((v - np.floor(v)) > t1), 0, 2).astype(int)
    warm_r, cool_r = (np.stack([hexrgb(c) for c in r]) for r in RAMPS[theme])
    rgb = np.where(cool[..., None], cool_r[step], warm_r[step])
    rgba = np.zeros((H, W, 4), np.uint8)
    rgba[..., :3] = rgb
    rgba[..., 3] = m * 255
    return rgba, m


def outlined(rgba, mask, width=1, color=(0, 0, 0)):
    """Adds a hard outline (in dots) around the mask, so the letters hold up over a scene."""
    p = width
    H, W = mask.shape
    big = np.zeros((H + 2 * p, W + 2 * p), bool)
    for dy in range(-p, p + 1):
        for dx in range(-p, p + 1):
            big[p + dy:p + dy + H, p + dx:p + dx + W] |= mask
    out = np.zeros((H + 2 * p, W + 2 * p, 4), np.uint8)
    out[big] = (*color, 255)
    inner = out[p:p + H, p:p + W]
    inner[mask] = rgba[mask]
    return out


def scale(rgba, k):
    return Image.fromarray(rgba).resize((rgba.shape[1] * k, rgba.shape[0] * k), Image.NEAREST)


def svg(rgba, dot, path):
    """Pixel-grid SVG: one rect per horizontal run of a color."""
    H, W, _ = rgba.shape
    rects = []
    for y in range(H):
        x = 0
        while x < W:
            if rgba[y, x, 3] == 0:
                x += 1
                continue
            c = rgba[y, x, :3]
            x0 = x
            while x < W and rgba[y, x, 3] and (rgba[y, x, :3] == c).all():
                x += 1
            rects.append(f'<rect x="{x0}" y="{y}" width="{x - x0}" height="1" fill="#{c[0]:02x}{c[1]:02x}{c[2]:02x}"/>')
    with open(path, "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W * dot}" height="{H * dot}" '
                f'shape-rendering="crispEdges"><title>Deep Field</title>\n' + "\n".join(rects) + "\n</svg>\n")


def text_image(text, cell, color):
    m = pixelfont.text_mask(text)
    rgba = np.zeros((*m.shape, 4), np.uint8)
    rgba[m] = (*color, 255)
    return scale(rgba, cell)


def icon(size):
    return Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)


def lockup(theme, dot, tagline=True, outline=False):
    """App icon with the wordmark beside it (and the tagline under the wordmark), transparent."""
    rgba, mask = wordmark_dots(theme)
    if outline:
        rgba = outlined(rgba, mask)
    wm = scale(rgba, dot)
    ic = icon(round(wm.height * 2.3))
    gap = round(wm.height * 0.25)
    tag = text_image(TAGLINE, max(1, round(dot * 0.62)), TAG_COLOR[theme]) if tagline else None
    if outline and tag is not None:
        tm = np.asarray(tag)[..., 3] > 0
        tag = Image.fromarray(outlined(np.asarray(tag), tm, width=max(1, dot // 2)))
    col_h = wm.height + ((gap + tag.height) if tag else 0)
    col_w = max(wm.width, tag.width if tag else 0)
    W = ic.width + gap + col_w
    H = max(ic.height, col_h)
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.alpha_composite(ic, (0, (H - ic.height) // 2))
    y = (H - col_h) // 2
    x = ic.width + gap
    out.alpha_composite(wm, (x, y))
    if tag:
        out.alpha_composite(tag, (x + dot, y + wm.height + gap))
    return out


# ---------- scene backgrounds ----------

def scene_plate(W, H, cell, scene="blackHole", hole_x=0.7, t=60, config=None, tag="plate"):
    """Renders the scene at height H, wide enough that its center can sit at hole_x * W, and crops."""
    half = max(hole_x, 1 - hole_x) * W
    R = int(np.ceil(2 * half / (2 * cell)) * 2 * cell)
    cfg = {"pixelSize": cell, **(config or {})}
    path = dfcli.snapshot(os.path.join(dfcli.WORK, "brand", f"{tag}-{W}x{H}.png"), scene, t, (R, H), cfg)
    im = np.asarray(Image.open(path).convert("RGB"))
    x0 = int(round((R / 2 - hole_x * W) / cell)) * cell
    return im[:, x0:x0 + W].copy()


def dither_fade(img, cell, start, end, axis_from_left=True):
    """Fades to black across [start, end] of the width, cell by cell along a Bayer threshold."""
    H, W, _ = img.shape
    yy, xx = np.mgrid[0:H, 0:W]
    u = xx / W
    f = np.clip((end - u) / (end - start), 0, 1)
    f = f * f * (3 - 2 * f)
    thr = B8[(yy // cell) % 8, (xx // cell) % 8]
    out = img.copy()
    out[thr < f] = 0
    return out


def rounded(im, r):
    """Rounded corners with an anti-aliased alpha edge, so it sits on light or dark pages."""
    ss = 4
    W, H = im.size
    yy, xx = np.mgrid[0:H * ss, 0:W * ss] / ss
    cx = np.clip(xx, r, W - r)
    cy = np.clip(yy, r, H - r)
    inside = ((xx - cx) ** 2 + (yy - cy) ** 2) <= r * r
    a = inside.reshape(H, ss, W, ss).mean((1, 3))
    out = im.convert("RGBA")
    arr = np.asarray(out).copy()
    arr[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(arr)


def hero(W, H, cell, dot, hole_x, fade, text_x, tagline=True, corner=0, zoom=None, tag="plate"):
    # zoom: the app's phone framing, used here to pull the camera back for taller frames
    cfg = {"phoneFraming": {"zoom": zoom, "shift": 0}} if zoom else None
    bg = scene_plate(W, H, cell, hole_x=hole_x, config=cfg, tag=tag)
    bg = dither_fade(bg, cell, *fade)
    im = Image.fromarray(bg).convert("RGBA")
    lk = lockup("dark", dot, tagline=tagline, outline=True)
    im.alpha_composite(lk, (round(text_x * W), (H - lk.height) // 2))
    return rounded(im, corner) if corner else im


# ---------- outputs ----------

def save(im, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path, optimize=True)
    print(path)


def favicons():
    d = os.path.join(SITE, "favicon")
    src = Image.open(ICON).convert("RGBA")
    for s in (16, 32, 48, 192, 512):
        save(src.resize((s, s), Image.LANCZOS), os.path.join(d, f"favicon-{s}.png" if s <= 48 else f"icon-{s}.png"))
    # apple-touch: iOS adds its own rounding, so fill the corners with black instead of transparency
    at = Image.new("RGBA", (1024, 1024), (0, 0, 0, 255))
    at.alpha_composite(src)
    save(at.convert("RGB").resize((180, 180), Image.LANCZOS), os.path.join(d, "apple-touch-icon.png"))
    src.save(os.path.join(d, "favicon.ico"), sizes=[(16, 16), (32, 32), (48, 48)])
    print(os.path.join(d, "favicon.ico"))
    with open(os.path.join(d, "site.webmanifest"), "w") as f:
        f.write('{\n  "name": "Deep Field",\n  "short_name": "Deep Field",\n  "icons": [\n'
                '    { "src": "icon-192.png", "sizes": "192x192", "type": "image/png" },\n'
                '    { "src": "icon-512.png", "sizes": "512x512", "type": "image/png" }\n  ],\n'
                '  "theme_color": "#0b0d12",\n  "background_color": "#000000",\n  "display": "standalone"\n}\n')


def main():
    # wordmark and logo, both themes
    for theme in ("dark", "light"):
        rgba, mask = wordmark_dots(theme)
        save(scale(rgba, 6), os.path.join(SITE, "logo", f"wordmark-{theme}.png"))
        svg(rgba, 6, os.path.join(SITE, "logo", f"wordmark-{theme}.svg"))
        save(lockup(theme, 6), os.path.join(SITE, "logo", f"logo-{theme}.png"))
        save(lockup(theme, 3, tagline=False), os.path.join(MEDIA, f"logo-{theme}.png"))

    # README banner (works on light and dark GitHub themes: its own dark plate, rounded corners)
    save(hero(1600, 520, 4, 4, hole_x=0.74, fade=(0.30, 0.62), text_x=0.045, corner=22, tag="banner"),
         os.path.join(MEDIA, "banner.png"))

    # website heroes and social cards
    save(hero(2560, 1200, 5, 6, hole_x=0.72, fade=(0.36, 0.62), text_x=0.06, zoom=0.24, tag="hero"),
         os.path.join(SITE, "hero", "hero-2560x1200.png"))
    save(hero(1920, 1080, 4, 5, hole_x=0.72, fade=(0.36, 0.62), text_x=0.06, zoom=0.26, tag="hero"),
         os.path.join(SITE, "hero", "hero-1920x1080.png"))
    save(hero(1200, 630, 3, 3, hole_x=0.75, fade=(0.36, 0.64), text_x=0.05, zoom=0.3, tag="og"),
         os.path.join(SITE, "social", "og-1200x630.png"))
    save(hero(1200, 675, 3, 3, hole_x=0.75, fade=(0.36, 0.64), text_x=0.05, zoom=0.3, tag="og"),
         os.path.join(SITE, "social", "twitter-1200x675.png"))
    favicons()


if __name__ == "__main__":
    main()
