#!/usr/bin/env python3
"""Turns the smoke test's panels into the README's pictures: each real capture, unchanged, on a plain drawn backdrop.

Play something in Spotify, run a smoke test pinned to it, then this. Pinning matters: without it the pictures show
whatever this Mac last played, like a video in your browser, so this script stops unless the capture came from Spotify.
It needs Pillow, which only this script uses (the app has no dependencies):

    BRIM_SMOKE_PLAYER=com.spotify.client BRIM_SMOKE_OUTPUT="$PWD/dist/smoke" dist/Brim.app/Contents/MacOS/Brim --smoke-test --check-media
    python3 scripts/compose-readme-images.py
"""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE, OUTPUT = ROOT / "dist/smoke", ROOT / "docs/images"
SCALE = 2
MENU_BAR = 32 * SCALE


def backdrop(width, height):
    """A soft four-color wash, drawn here so no wallpaper or anyone's desktop ends up in the pictures."""
    corners = Image.new("RGB", (2, 2))
    corners.putdata([(24, 34, 92), (86, 58, 140), (58, 78, 158), (196, 104, 138)])
    return corners.resize((width, height), Image.BICUBIC).convert("RGBA")


def rounded(image, radius=28 * SCALE // 2):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius, fill=255)
    image.putalpha(mask)
    return image


def on_menu_bar(name, output, width=1100, below=56):
    """The island hangs from the top edge, so it goes where it really lives: under a menu bar, against the top."""
    panel = Image.open(SOURCE / f"{name}.png").convert("RGBA")
    box = panel.getbbox()
    island = panel.crop((box[0], 0, box[2], box[3]))
    canvas = backdrop(width, max(island.height + below, MENU_BAR + below))
    canvas.alpha_composite(Image.new("RGBA", (width, MENU_BAR), (0, 0, 0, 56)))
    canvas.alpha_composite(island, ((width - island.width) // 2, 0))
    rounded(canvas).save(OUTPUT / f"{output}.png", optimize=True)


def floating(name, output, margin=64):
    """Windows float over the desktop rather than hanging from the menu bar."""
    panel = Image.open(SOURCE / f"{name}.png").convert("RGBA")
    canvas = backdrop(panel.width + margin * 2, panel.height + margin * 2)
    canvas.alpha_composite(panel, (margin, margin))
    rounded(canvas).save(OUTPUT / f"{output}.png", optimize=True)


def as_is(name, output, width=None):
    image = Image.open(SOURCE / f"{name}.png").convert("RGBA")
    if width:
        image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
    rounded(image, 20).save(OUTPUT / f"{output}.png", optimize=True)


shown = json.loads((SOURCE / "report.json").read_text()).get("mediaCheck", {}).get("shownPlayer")
if shown != "com.spotify.client":
    sys.exit(f"The island was showing {shown!r}, not Spotify, so these pictures could show something private.")
OUTPUT.mkdir(parents=True, exist_ok=True)
on_menu_bar("essentials-home", "hero", width=1600, below=96)
for name, output in [
    ("island-compact", "compact-music"), ("dual-live", "dual-activities"), ("island-expanded", "player"),
    ("file-shelf-items", "files"), ("drop-zones", "drop-zones"), ("clipboard-pins", "clipboard"), ("timer-running", "timer"),
    ("battery-pane", "battery"), ("accessory-card", "airpods"), ("activity-expanded", "activity"),
]:
    on_menu_bar(name, output)
floating("switcher-previews", "switcher")
as_is("dynamic-island-dark", "settings", width=1100)
as_is("duo-fold-50", "lid-fold", width=1100)
as_is("scale", "scale", width=620)
for file in sorted(OUTPUT.glob("*.png")):
    print(f"{file.name}: {file.stat().st_size // 1024} KB")
