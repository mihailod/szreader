#!/usr/bin/env python3
"""Draws the document icons — what a .cbz/.cbr/.cb7 looks like in the Files app.

    ./scripts/document-icons.py

Writes App/DocumentIcons/. Committed output: the build needs the PNGs, and this
script is here so the next person can see where they came from and change them
without redrawing by hand.

Derived from the app icon rather than merely matching it: the four colours below
are sampled out of icon_1024.png, so a repaint of the app icon is a re-run of
this rather than a colour to hunt down. The composition is the app icon's minus
the open book — a starburst on blue, with the format where the "SZ" is. The book
is what goes: it is the detail that turns to mush first, and these are seen at
64 points and often at 22.

No page shape, no folded corner. Whether iOS composites one of its own onto a
document icon is genuinely undocumented — Apple's own forum thread on this key
ends without an answer — so the artwork is a full-bleed square that reads either
way. Drawing a page here and having the system draw another around it is the one
outcome that would look broken.
"""

import os
from PIL import Image, ImageDraw, ImageFont

# Sampled from App/Assets.xcassets/AppIcon.appiconset/icon_1024.png.
BLUE = (1, 56, 169)
RED = (221, 11, 13)
WHITE = (254, 255, 255)
BLACK = (8, 7, 7)

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

# Drawn once at this size and reduced to each of the sizes below, which is
# cheaper than tuning line weights per size and gives the small ones antialiased
# edges instead of the staircase a direct draw would.
MASTER = 1024

# From Apple's document-icon table: the square pair is what iPad uses, the
# portrait pair is iPhone's. Both are wanted — the app is universal — and the
# portrait ones are not a crop but the same square letterboxed, because a
# composition that reads at 22x29 has no room to be composed twice.
SIZES = [("22x29", 22, 29), ("64", 64, 64), ("320", 320, 320)]

FORMATS = ["CBZ", "CBR", "CB7"]


def starburst(draw, cx, cy, outer, inner, points=12):
    """The comic-book burst the app icon is built around.

    Twelve points rather than the app icon's sixteen. The spikes are what
    survives being reduced to a thumbnail, and fewer of them means each one is
    still a spike at 64 pixels instead of a serrated edge.
    """
    import math

    xy = []
    for i in range(points * 2):
        # Rotated a half-step so a point, not a valley, sits at the top.
        angle = math.pi * i / points - math.pi / 2 + math.pi / (points * 2)
        r = outer if i % 2 == 0 else inner
        xy.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))
    draw.polygon(xy, fill=WHITE, outline=BLACK, width=int(MASTER * 0.018))


def master_for(label):
    """One format's artwork at full size."""
    im = Image.new("RGBA", (MASTER, MASTER), BLUE + (255,))
    draw = ImageDraw.Draw(im)
    centre = MASTER / 2
    starburst(draw, centre, centre, MASTER * 0.46, MASTER * 0.38)

    # Grown until the label spans the burst's flat middle rather than being set
    # at a size that happens to look right for three capitals — "CB7" and "CBZ"
    # are not the same width in this face.
    target = MASTER * 0.54
    size = int(MASTER * 0.3)
    while size < MASTER:
        font = ImageFont.truetype(FONT, size)
        left, _, right, _ = draw.textbbox((0, 0), label, font=font)
        if right - left >= target:
            break
        size += 4

    font = ImageFont.truetype(FONT, size)
    draw.text((centre, centre), label, font=font, fill=RED,
              anchor="mm", stroke_width=int(MASTER * 0.022), stroke_fill=BLACK)
    return im


def main():
    out = os.path.join(os.path.dirname(__file__), "..", "App", "DocumentIcons")
    out = os.path.normpath(out)
    os.makedirs(out, exist_ok=True)

    written = 0
    for label in FORMATS:
        art = master_for(label)
        for name, w, h in SIZES:
            for scale, suffix in ((1, ""), (2, "@2x")):
                box = (w * scale, h * scale)
                # Square art onto a portrait canvas: reduced to the shorter
                # side and centred, with the blue carried out to the edges so
                # the icon still fills its rectangle.
                side = min(box)
                shrunk = art.resize((side, side), Image.LANCZOS)
                canvas = Image.new("RGBA", box, BLUE + (255,))
                canvas.paste(shrunk, ((box[0] - side) // 2, (box[1] - side) // 2))
                path = os.path.join(
                    out, "doc-%s-%s%s.png" % (label.lower(), name, suffix))
                canvas.save(path)
                written += 1
    print("wrote %d icons to %s" % (written, out))


if __name__ == "__main__":
    main()
