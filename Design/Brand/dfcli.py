"""Thin wrapper around the app's dev CLI (see the README's Dev tools section).

Every render starts from the default settings (`--defaults`) plus an explicit config patch, so
the output never depends on the saved settings, and nothing here writes to them.
"""
import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BIN = os.environ.get("DEEPFIELD_BIN", os.path.join(ROOT, "build/DeepField.app/Contents/MacOS/DeepField"))
WORK = os.path.join(HERE, "output")          # intermediate renders, git-ignored


def snapshot(out, scene, t, size, config=None, demo=None, events=True, preset=None):
    """One deterministic frame, nearest-neighbor upscaled by the config's pixel size."""
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = [BIN, "--snapshot", out, "--defaults", "--scene", scene, "--time", f"{t:.4f}",
           "--size", f"{size[0]}x{size[1]}"]
    if config:
        cmd += ["--config", json.dumps(config)]
    if demo:
        cmd += ["--demo", ",".join(f"{k}:{v}" for k, v in demo.items())]
    if not events:
        cmd += ["--no-events"]
    if preset:
        cmd += ["--preset", preset]
    subprocess.run(cmd, check=True)
    return out


def frames(tag, scene, times, size, config=None, demo=None, events=True, preset=None, jobs=6):
    """Renders a list of times in parallel; returns the frames as uint8 RGB arrays."""
    d = os.path.join(WORK, "frames", tag)
    os.makedirs(d, exist_ok=True)
    paths = [os.path.join(d, f"{i:04d}.png") for i in range(len(times))]
    with ThreadPoolExecutor(jobs) as ex:
        list(ex.map(lambda a: snapshot(a[0], scene, a[1], size, config, demo, events, preset),
                    zip(paths, times)))
    return [np.asarray(Image.open(p).convert("RGB")) for p in paths]


def load(path):
    return np.asarray(Image.open(path).convert("RGB"))
