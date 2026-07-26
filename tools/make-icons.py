#!/usr/bin/env python3
"""Turn the pixel-art masters in Assets/source into menu bar assets.

Run after editing the art:  python3 tools/make-icons.py && ./build.sh

Two different jobs:

* awake - stays in colour. Orange body plus green core is the whole point of
          the state, and colour opts it out of template tinting.
* sleep - becomes a template mask (alpha only). The master is an opaque white
          body, which would be invisible on a light menu bar, so alpha is
          derived from darkness and macOS tints it per appearance.

If a master floats a detached accent above the body (a zZz, say), it is tucked
into the top-right corner rather than left hovering. Fitting art plus a floating
accent into an 18pt box otherwise leaves the creature about half height next to
the other state. Detected automatically, so adding or removing the accent needs
no code change.
"""
from PIL import Image
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Assets" / "source"
OUT = ROOT / "Assets"

HEIGHT = 20       # canvas height; the extra over CONTENT is room to nudge
CONTENT = 16      # how tall the art itself renders
FLOOR = 8         # ignore near invisible fringe pixels when cropping


def trim(image):
    """Crop to real content, ignoring the faint antialiased fringe."""
    alpha = image.split()[3].point(lambda v: 255 if v > FLOOR else 0)
    box = alpha.getbbox()
    return image.crop(box) if box else image


def template_mask(image):
    """Alpha from darkness, in three bands so nothing washes out at 18pt."""
    pixels = image.load()
    mask = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out = mask.load()
    for y in range(image.size[1]):
        for x in range(image.size[0]):
            r, g, b, a = pixels[x, y]
            if a <= FLOOR:
                continue
            lum = (r * 299 + g * 587 + b * 114) // 1000
            if lum < 110:
                alpha = 255      # eyes and other dark detail, full strength
            elif lum < 236:
                alpha = 170      # outline, firm enough to survive downscaling
            else:
                alpha = 95       # body interior, soft fill so it reads as a shape
            out[x, y] = (0, 0, 0, alpha)
    return mask


def split_accent(image):
    """Return (body, accent) if a detached accent floats above the body."""
    alpha = image.split()[3]
    rows = [alpha.crop((0, y, image.size[0], y + 1)).getextrema()[1] > FLOOR
            for y in range(image.size[1])]
    bands, start = [], None
    for y, filled in enumerate(rows + [False]):
        if filled and start is None:
            start = y
        elif not filled and start is not None:
            bands.append((start, y))
            start = None
    if len(bands) < 2:
        return image, None
    top, rest = bands[0], bands[-1]
    # Only an accent if the upper band is a minority of the art.
    if (top[1] - top[0]) > 0.4 * (rest[1] - top[0]):
        return image, None
    return trim(image.crop((0, rest[0], image.size[0], image.size[1]))), \
           trim(image.crop((0, top[0], image.size[0], top[1])))


def tuck(body, accent):
    """Pull a floating accent into the body's top-right corner."""
    bw, bh = body.size
    ah = int(bh * 0.26)
    aw = int(accent.size[0] * ah / accent.size[1])
    accent = accent.resize((aw, ah), Image.LANCZOS)

    overlap = int(ah * 0.55)       # vertical bite into the body
    inset = int(aw * 0.70)         # horizontal overlap with the body
    canvas = Image.new("RGBA", (bw + max(0, aw - inset), bh + ah - overlap), (0, 0, 0, 0))

    # alpha_composite, not paste-with-mask: pasting a partially transparent
    # image using itself as the mask squares its alpha and dims the body.
    for art, pos in ((body, (0, canvas.size[1] - bh)), (accent, (canvas.size[0] - aw, 0))):
        layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        layer.paste(art, pos)
        canvas = Image.alpha_composite(canvas, layer)
    return trim(canvas)


def art_width(image):
    """Width in points once the art is scaled to CONTENT height."""
    w, h = image.size
    return max(1, round(w * CONTENT / h))


def optical_shift(image, limit):
    """Pixels to nudge down so the art's visual mass, not its bounding box,
    sits on the centre line.

    The creature's head is dense and its legs are thin outlines, so a
    geometrically centred icon carries its weight high and reads as sitting
    above its neighbours in the menu bar. Aligning the alpha-weighted centroid
    fixes that. Clamped to the padding available, so nothing ever clips.
    """
    pixels = image.load()
    w, h = image.size
    total = weighted = 0
    for y in range(h):
        row = sum(pixels[x, y][3] for x in range(w))
        total += row
        weighted += row * y
    if total == 0:
        return 0
    offset = h / 2 - weighted / total
    return max(-limit, min(limit, round(offset)))


def fit(image, scale, canvas_width):
    """Scale to the target height and place on a shared canvas.

    Both states share one canvas so the status item never changes size when it
    toggles. Widths are derived at 1x and doubled for 2x, never rounded
    independently: a 41px 2x asset is 20.5pt, cannot halve cleanly, and ends up
    off centre.
    """
    content = CONTENT * scale
    width = max(1, round(image.size[0] * CONTENT / image.size[1])) * scale
    resized = image.resize((width, content), Image.LANCZOS)
    canvas = Image.new("RGBA", (canvas_width * scale, HEIGHT * scale), (0, 0, 0, 0))
    pad = (canvas.size[1] - content) // 2
    canvas.paste(resized, ((canvas.size[0] - resized.size[0]) // 2,
                           pad + optical_shift(resized, pad)))
    return canvas


def prepare(name):
    art = trim(Image.open(SRC / f"{name}.png").convert("RGBA"))
    if name == "sleep":
        art = template_mask(art)
    body, accent = split_accent(art)
    if accent is not None:
        print(f"  {name}: tucking detached accent {accent.size} into the corner")
        return tuck(body, accent)
    return body


arts = {name: prepare(name) for name in ("awake", "sleep")}

# One shared width for both states, padded so each side is an equal whole
# number of pixels at 1x as well as 2x.
canvas_width = max([HEIGHT] + [art_width(a) for a in arts.values()])
if any((canvas_width - art_width(a)) % 2 for a in arts.values()):
    canvas_width += 1
print(f"shared canvas: {canvas_width}x{HEIGHT}pt")

for name, art in arts.items():
    for scale, suffix in ((1, ""), (2, "@2x")):
        path = OUT / f"{name}{suffix}.png"
        image = fit(art, scale, canvas_width)
        image.save(path)
        print(f"wrote {path.relative_to(ROOT)}  {image.size[0]}x{image.size[1]}px")
