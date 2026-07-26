#!/usr/bin/env python3
"""Build AppIcon.icns from the awake mascot.

Run:  python3 tools/make-appicon.py && ./build.sh

The app is LSUIElement so it has no Dock icon, but it still shows up in Finder,
Spotlight and, now that it launches at login, System Settings. A blank default
icon there looks broken.

The mascot sits on a rounded square the way macOS icons do, rather than floating
on transparency, so it reads as an app rather than a loose sticker.
"""
from PIL import Image, ImageDraw
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Assets" / "source" / "awake.png"
OUT = ROOT / "Assets" / "AppIcon.icns"

BACKDROP = (38, 38, 42, 255)   # charcoal, so the orange mascot pops
MARGIN = 0.16                  # share of the canvas left as padding
RADIUS = 0.22                  # corner radius as a share of the canvas


def render(size):
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle([0, 0, size - 1, size - 1],
                           radius=int(size * RADIUS), fill=BACKDROP)

    art = Image.open(SRC).convert("RGBA")
    art = art.crop(art.split()[3].point(lambda v: 255 if v > 8 else 0).getbbox())
    room = int(size * (1 - MARGIN * 2))
    scale = min(room / art.size[0], room / art.size[1])
    art = art.resize((max(1, round(art.size[0] * scale)), max(1, round(art.size[1] * scale))),
                     Image.LANCZOS)
    canvas.alpha_composite(art, ((size - art.size[0]) // 2, (size - art.size[1]) // 2))
    return canvas


with tempfile.TemporaryDirectory() as tmp:
    iconset = pathlib.Path(tmp) / "AppIcon.iconset"
    iconset.mkdir()
    for base in (16, 32, 128, 256, 512):
        render(base).save(iconset / f"icon_{base}x{base}.png")
        render(base * 2).save(iconset / f"icon_{base}x{base}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)

print("wrote", OUT.relative_to(ROOT))
