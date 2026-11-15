import numpy as np
from PIL import Image, ImageFilter, ImageDraw, ImageFont
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
os.makedirs(OUT, exist_ok=True)

CANVAS = 1024
BODY = 824

# ---------- squircle mask, shadow, framing ----------

def squircle_mask(size=BODY, n=5.0, ss=4):
    s = size * ss
    c = (np.arange(s) + 0.5) / s * 2 - 1
    x, y = np.meshgrid(c, c)
    m = (np.abs(x) ** n + np.abs(y) ** n) <= 1.0
    img = Image.fromarray((m * 255).astype(np.uint8))
    return img.resize((size, size), Image.LANCZOS)

MASK = squircle_mask()

def frame(art):
    """art: RGB PIL image >= BODY, centered and clipped to the squircle on a 1024 canvas."""
    w, h = art.size
    l, t = (w - BODY) // 2, (h - BODY) // 2
    art = art.crop((l, t, l + BODY, t + BODY)).convert("RGBA")
    # faint rim so dark icons separate from dark backgrounds
    rim = squircle_mask(BODY - 6)
    rim_full = Image.new("L", (BODY, BODY), 0)
    rim_full.paste(rim, (3, 3))
    edge = np.clip(np.asarray(MASK, np.float32) - np.asarray(rim_full, np.float32), 0, 255) / 255
    a = np.asarray(art, np.float32)
    a[..., :3] = a[..., :3] * (1 - edge[..., None] * 0.22) + 255 * edge[..., None] * 0.22
    art = Image.fromarray(a.astype(np.uint8))
    art.putalpha(MASK)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BODY) // 2
    sh = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    sha = Image.new("L", (CANVAS, CANVAS), 0)
    sha.paste(MASK, (off, off + 10))
    sha = sha.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.45))
    sh.putalpha(sha)
    canvas.alpha_composite(sh)
    canvas.alpha_composite(art, (off, off))
    return canvas

def upscale(cells, minsize=BODY):
    """cells: HxWx3 uint8 grid; nearest-neighbor scale to the smallest integer factor covering BODY."""
    h, w, _ = cells.shape
    k = int(np.ceil(minsize / min(h, w)))
    return Image.fromarray(cells).resize((w * k, h * k), Image.NEAREST)

# ---------- dithering helpers ----------

def bayer(n):
    m = np.array([[0]])
    while m.shape[0] < n:
        m = np.block([[4 * m, 4 * m + 2], [4 * m + 3, 4 * m + 1]])
    return (m + 0.5) / m.size

B8 = bayer(8)

def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.uint8)

WARM = [hexrgb(c) for c in ["000000", "3a0f04", "9a3208", "f2700f", "ffb347", "fff1d6"]]
COOL = [hexrgb(c) for c in ["000000", "0b1a4a", "1f4fd8", "4aa6ff", "b6e6ff", "ffffff"]]

def dither_two_ramps(v, h, ramps=(WARM, COOL), off=(0, 0)):
    """v: intensity 0..1, h: 0 warm .. 1 cool. Ordered dither both the ramp step and the hue choice."""
    H, W = v.shape
    yy, xx = np.mgrid[0:H, 0:W]
    t = B8[(yy + off[0]) % 8, (xx + off[1]) % 8]
    t2 = B8[(yy + 3 + off[0]) % 8, (xx + 5 + off[1]) % 8]
    n = len(ramps[0]) - 1
    f = np.clip(v, 0, 1) * n
    lo = np.floor(f).astype(int)
    step = np.clip(lo + ((f - lo) > t), 0, n)
    cool = np.clip(h, 0, 1) > t2
    out = np.zeros((H, W, 3), np.uint8)
    wr, cr = np.stack(ramps[0]), np.stack(ramps[1])
    out[~cool] = wr[step[~cool]]
    out[cool] = cr[step[cool]]
    return out

def grid(N):
    c = (np.arange(N) + 0.5) / N * 2 - 1
    x, y = np.meshgrid(c, c)
    return x, y

def g(x, s):
    return np.exp(-(x / s) ** 2)

# ---------- render-based options ----------

def from_render(path, cx, cy, size, ps=2, clean=0.0):
    im = np.asarray(Image.open(path).convert("RGB"))
    cells = im[ps // 2::ps, ps // 2::ps]
    x0, y0 = cx - size // 2, cy - size // 2
    cells = cells[y0:y0 + size, x0:x0 + size].copy()
    if clean > 0:
        c = cells.astype(int)
        lum = c.max(axis=2) / 255.0
        gray = (c.max(axis=2) - c.min(axis=2)) < 40
        # drop the sparse dim dither dots of the sky haze so the object reads at small sizes
        cells[(lum < clean) | (gray & (lum < 0.6))] = 0
        on = cells.max(axis=2) > 0
        p = np.pad(on, 1)
        nb = sum(p[1 + dy:1 + dy + on.shape[0], 1 + dx:1 + dx + on.shape[1]]
                 for dy in (-1, 0, 1) for dx in (-1, 0, 1)) - on
        lum = cells.max(axis=2) / 255.0
        cells[on & (nb < 2) & (lum < 0.75)] = 0
    return cells

# ---------- procedural black hole ----------

def black_hole_field(N, R0=0.30, tilt=0.12, disk_out=1.0):
    x, y = grid(N)
    r = np.hypot(x, y)
    # lensed back of the disk: bright arc over the top, faint thin one underneath
    halo_up = g(r - (R0 + 0.15), 0.14) * (y < 0.02) * 0.8
    halo_dn = g(r - (R0 + 0.06), 0.06) * (y >= 0.02) * 0.5
    ring = g(r - (R0 + 0.03), 0.035) * 0.9
    v = np.maximum(np.maximum(halo_up, halo_dn), ring)
    # front disk: thin flat band across the whole width, in front of the shadow
    hh = disk_out * tilt
    band = np.clip(1 - np.abs(x) / disk_out, 0, 1) ** 0.45 * g(y - 0.015, hh)
    v = np.maximum(v, band * 0.9)
    v = np.where((r < R0) & (band < 0.35), 0.0, v)
    # Doppler: left approaching (cool, brighter), right receding (warm, dimmer)
    hue = 1 / (1 + np.exp((x + 0.02) / 0.1))
    v = v * (0.88 + 0.3 * hue)
    return np.clip(v, 0, 1), hue

def opt_minimal():
    N = 24
    v, hue = black_hole_field(N, R0=0.33, tilt=0.09)
    return dither_two_ramps(v, hue)

def opt_ring():
    """Face-on Einstein ring: warm top, cool bottom, deep black center."""
    N = 32
    x, y = grid(N)
    r = np.hypot(x, y)
    ang = np.arctan2(y, x)
    v = g(r - 0.58, 0.2) * 1.1 + g(r - 0.52, 0.07) * 0.5
    v = v * (0.75 + 0.25 * np.cos(ang + 2.4))
    v = np.where(r < 0.36, 0, v)
    hue = np.clip(0.5 + 0.9 * np.sin(ang - 0.0) * 0.8 + 0.5 * x * 0, 0, 1)
    hue = 1 / (1 + np.exp(-(np.sin(ang + 0.5)) / 0.18))
    return dither_two_ramps(np.clip(v, 0, 1), hue)

def opt_deepfield():
    N = 40
    rng = np.random.default_rng(7)
    x, y = grid(N)
    v = np.zeros((N, N))
    hue = np.zeros((N, N))
    # faint galaxy smudges
    for _ in range(9):
        cx, cy = rng.uniform(-0.9, 0.9, 2)
        if np.hypot(cx - 0.0, cy - 0.0) < 0.7:
            continue
        a = rng.uniform(0, np.pi)
        dx, dy = x - cx, y - cy
        u = dx * np.cos(a) + dy * np.sin(a)
        w = -dx * np.sin(a) + dy * np.cos(a)
        s = rng.uniform(0.04, 0.08)
        val = np.exp(-(u / s) ** 2 - (w / (s * 0.45)) ** 2) * rng.uniform(0.35, 0.6)
        h = rng.uniform(0, 1) > 0.5
        hue = np.where(val > v, float(h), hue)
        v = np.maximum(v, val)
    # lensed object: Einstein arcs around a warm foreground galaxy
    r = np.hypot(x, y)
    ang = np.arctan2(y, x)
    arcs = g(r - 0.5, 0.08) * (0.25 + 0.75 * np.clip(np.cos(2 * (ang - 0.6)), 0, 1) ** 0.6)
    core = g(r, 0.16)
    v = np.maximum(v, arcs * 1.05)
    hue = np.where(arcs * 1.05 >= v - 1e-6, 1.0, hue)
    v = np.maximum(v, core)
    hue = np.where(core >= v - 1e-6, 0.0, hue)
    out = dither_two_ramps(np.clip(v, 0, 1), hue)
    # crisp stars with diffraction crosses
    stars = [(-0.62, -0.6, 1, 2), (0.66, 0.58, 0, 2), (0.7, -0.68, 1, 1), (-0.72, 0.7, 0, 1)]
    for sx, sy, cool, arm in stars:
        i, j = int((sy + 1) / 2 * N), int((sx + 1) / 2 * N)
        ramp = COOL if cool else WARM
        out[i, j] = ramp[5]
        for k in range(1, arm + 1):
            col = ramp[4] if k == 1 else ramp[2]
            for di, dj in ((k, 0), (-k, 0), (0, k), (0, -k)):
                out[i + di, j + dj] = col
    for _ in range(14):
        i, j = rng.integers(0, N, 2)
        if np.hypot(i - N / 2, j - N / 2) < N * 0.3:
            continue
        if out[i, j].max() == 0:
            out[i, j] = (COOL if rng.uniform() > 0.5 else WARM)[rng.integers(2, 4)]
    return out

def main():
    src = os.path.join(HERE, "renders")
    opts = []
    garg = from_render(f"{src}/src_garg.png", 62, 66, 68, clean=0.3)
    opts.append(("gargantua", garg))
    syn = from_render(f"{src}/src_syn.png", 62, 66, 68, clean=0.3)
    opts.append(("synthwave", syn))
    opts.append(("pixel-mark", opt_minimal()))
    gal = from_render(f"{src}/src_gal.png", 64, 64, 96, clean=0.42)
    opts.append(("galaxy", gal))
    opts.append(("deep-field", opt_deepfield()))
    opts.append(("photon-ring", opt_ring()))
    sel = sys.argv[1:]
    for i, (name, cells) in enumerate(opts, 1):
        if sel and str(i) not in sel:
            continue
        icon = frame(upscale(cells))
        icon.save(f"{OUT}/option-{i}-{name}.png")
    return opts

if __name__ == "__main__":
    main()
