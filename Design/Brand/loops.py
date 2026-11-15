"""Seamless loops from the app's snapshots, encoded as GIF (README) and MP4 (website).

A loop of N frames starting at t0 also renders the K frames just before t0. The last K frames
dissolve into those, cell by cell along a Bayer threshold (the same trick the app's Live Photo
export uses), so frame N-1 is almost frame t0 - dt and the loop wraps without a jump. Every
output pixel is still one of the app's own colors, so the GIF palette is exact.
"""
import os
import shutil
import subprocess
import tempfile

import numpy as np
from PIL import Image

import dfcli


def bayer(n):
    m = np.array([[0]])
    while m.shape[0] < n:
        m = np.block([[4 * m, 4 * m + 2], [4 * m + 3, 4 * m + 1]])
    return (m + 0.5) / m.size


def dissolve_loop(tag, scene, t0, seconds, fps, size, cell, config=None, demo=None,
                  blend=1.0, speed=1.0, events=True, preset=None):
    """seconds and blend are output seconds; scene time runs speed times faster."""
    n = round(seconds * fps)
    k = round(blend * fps) if blend > 0 else 0
    dt = speed / fps
    times = [t0 - (k - i) * dt for i in range(k)] + [t0 + i * dt for i in range(n)]
    fr = dfcli.frames(tag, scene, times, size, {"pixelSize": cell, **(config or {})}, demo, events, preset)
    pre, main = fr[:k], fr[k:]
    if k == 0:
        return main
    h, w, _ = main[0].shape
    yy, xx = np.mgrid[0:h, 0:w]
    thr = bayer(8)[(yy // cell) % 8, (xx // cell) % 8]
    out = list(main)
    for j in range(k):
        i = n - k + j
        mask = thr < (j + 1) / (k + 1)
        f = main[i].copy()
        f[mask] = pre[j][mask]
        out[i] = f
    return out


def _write_seq(frames, d):
    for i, f in enumerate(frames):
        Image.fromarray(f).save(os.path.join(d, f"{i:04d}.png"))


def gif(frames, fps, out, scale=1):
    """Palette GIF; the frames hold at most the app's 5x5x5 levels, so no dithering is added."""
    os.makedirs(os.path.dirname(out), exist_ok=True)
    d = tempfile.mkdtemp()
    try:
        _write_seq(frames, d)
        vf = f"scale=iw*{scale}:ih*{scale}:flags=neighbor," if scale != 1 else ""
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(fps), "-i", f"{d}/%04d.png",
                        "-filter_complex",
                        f"[0:v]{vf}split[a][b];[a]palettegen=max_colors=256:stats_mode=full:reserve_transparent=0[p];"
                        f"[b][p]paletteuse=dither=none:diff_mode=rectangle",
                        "-loop", "0", out], check=True)
    finally:
        shutil.rmtree(d)
    return out


def mp4(frames, fps, out, crf=20, scale=1):
    """H.264, yuv420p, faststart. Upscaled with nearest neighbor first (scale) so chroma
    subsampling doesn't smear single dither cells."""
    os.makedirs(os.path.dirname(out), exist_ok=True)
    d = tempfile.mkdtemp()
    try:
        _write_seq(frames, d)
        vf = f"scale=iw*{scale}:ih*{scale}:flags=neighbor," if scale != 1 else ""
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(fps), "-i", f"{d}/%04d.png",
                        "-vf", f"{vf}format=yuv420p", "-c:v", "libx264", "-preset", "slow", "-crf", str(crf),
                        "-tune", "animation", "-movflags", "+faststart", "-an", out], check=True)
    finally:
        shutil.rmtree(d)
    return out


def poster(frame, out):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    Image.fromarray(frame).save(out, optimize=True)
    return out
