#!/usr/bin/env python3
"""Generate every icon the app ships, from the two corgi source images.

    python3 assets/make_icons.py          # writes into assets/

Sources (both 716x716 RGBA line art, identical alpha, different ink):
    corgi-ink.png    dark  — for light surfaces: the app icon
    corgi-white.png  white — for coloured surfaces: manager header, About
                             window, and the menu bar template

Outputs:
    AppIcon.icns     app icon: ink corgi on a paper squircle
    icon-1024.png    same at 1024, for listings and the website
    xl-corgi.png     header logo: white fill, black strokes
    menubar.png      menu bar template, 18pt
    menubar@2x.png   menu bar template, 36px

Only Pillow is required; nothing here needs macOS, so CI can regenerate.
"""
import io
import math
import os
import struct

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
INK = os.path.join(HERE, "corgi-ink.png")
WHITE = os.path.join(HERE, "corgi-white.png")

PAPER = (247, 245, 239, 255)   # --paper, the manager's own background
GREEN = (15, 106, 63)          # --accent
GOLD = (245, 197, 66)          # the chart line from the previous icon


def squircle(size, fill, n=5.0):
    """Apple-style rounded square: a superellipse, not a rounded rectangle.

    Drawn at 8x and downsampled — supersampling is far simpler than getting
    the antialiasing right analytically on a curve this shallow.
    """
    ss = size * 8
    mask = Image.new("L", (ss, ss), 0)
    d = ImageDraw.Draw(mask)
    r = ss / 2.0
    cx = cy = ss / 2.0
    pts = []
    steps = 2048
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + r * (abs(ct) ** (2.0 / n)) * (1 if ct >= 0 else -1)
        y = cy + r * (abs(st) ** (2.0 / n)) * (1 if st >= 0 else -1)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(Image.new("RGBA", (size, size), fill), (0, 0), mask)
    return out


def app_icon(px):
    """Ink corgi on a paper squircle, keeping a trace of the old wordmark."""
    icon = squircle(px, PAPER)

    # Faint gridlines and the rising chart line, carried over from the
    # previous icon so the app still reads as a spreadsheet tool.
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w = max(1, round(px / 256))
    for frac in (0.25, 0.5, 0.75):
        p = round(px * frac)
        d.line([(0, p), (px, p)], fill=GREEN + (16,), width=w)
        d.line([(p, 0), (p, px)], fill=GREEN + (16,), width=w)
    d.line(
        [(px * .10, px * .80), (px * .33, px * .64),
         (px * .52, px * .70), (px * .90, px * .34)],
        fill=GOLD + (70,), width=max(2, round(px * 0.026)), joint="curve")
    icon = Image.alpha_composite(icon, layer)

    # Corgi at 72% of the canvas, nudged down slightly: the ears carry a lot
    # of visual weight, so geometric centring reads as sitting too high.
    corgi = Image.open(INK).convert("RGBA")
    side = round(px * 0.72)
    corgi = corgi.resize((side, side), Image.LANCZOS)
    ox = (px - side) // 2
    oy = round((px - side) / 2 + px * 0.015)
    icon.alpha_composite(corgi, (ox, oy))
    return icon


def write_icns(path):
    # PNG-in-ICNS is valid for all of these type codes.
    sizes = {"icp4": 16, "icp5": 32, "icp6": 64, "ic07": 128, "ic08": 256,
             "ic09": 512, "ic10": 1024, "ic11": 32, "ic12": 64,
             "ic13": 512, "ic14": 1024}
    rendered, chunks = {}, b""
    for typ, px in sizes.items():
        if px not in rendered:
            buf = io.BytesIO()
            app_icon(px).save(buf, format="PNG")
            rendered[px] = buf.getvalue()
        png = rendered[px]
        chunks += typ.encode() + struct.pack(">I", 8 + len(png)) + png
    icns = b"icns" + struct.pack(">I", 8 + len(chunks)) + chunks
    with open(path, "wb") as f:
        f.write(icns)
    return len(icns)


def _jaw_tip(stroke, half):
    """Lowest stroke pixel in the left (0) or right (1) half of the image."""
    w, h = stroke.size
    px = stroke.load()
    x0, x1 = (0, w // 2) if half == 0 else (w // 2, w)
    for y in range(h - 1, -1, -1):
        for x in range(x0, x1):
            if px[x, y] > 128:
                return (x, y)
    return (x0, h - 1)


def filled_corgi(px, seal=18):
    """The header logo: enclosed areas filled white, strokes left black.

    The interior is found by flood-filling the background inward from a
    corner — everything the flood cannot reach is inside the corgi. The
    outline is not a closed path though (the chin is open, and the blaze
    lines stop short of the muzzle), so the flood escapes into the face
    and nothing fills. The stroke mask is therefore dilated first to seal
    those gaps, and the recovered interior is dilated back by the same
    amount afterwards.

    `seal` is bounded on both sides and was measured, not guessed: below
    14 the blaze stays hollow because the flood still gets in through the
    chin; at 36 the dilation swallows the cheeks entirely. 18 sits clear
    of both.
    """
    src = Image.open(INK).convert("RGBA")
    stroke = src.getchannel("A").point(lambda v: 255 if v > 110 else 0)

    # The jaw is drawn open: the two lower fur curves stop 333px apart and
    # the chin is implied rather than drawn. Nothing closes the silhouette
    # down there, so the flood walks straight up into the muzzle and the
    # mouth ends up sitting on bare background instead of on white. Join
    # the two lowest stroke tips with a line — on the mask only, never on
    # the artwork — so the head reads as closed for filling purposes.
    closed = stroke.copy()
    ImageDraw.Draw(closed).line([_jaw_tip(stroke, 0), _jaw_tip(stroke, 1)],
                                fill=255, width=max(4, src.width // 90))

    sealed = closed.filter(ImageFilter.MaxFilter(2 * seal + 1))
    flooded = sealed.copy()
    ImageDraw.floodfill(flooded, (0, 0), 128)
    outside = flooded.point(lambda v: 255 if v == 128 else 0)

    # Grow the OUTSIDE back by the same amount and fill everything else,
    # rather than growing the inside. Same result over large areas, but it
    # also catches pockets smaller than the seal radius — the slivers
    # where an eye meets a blaze line were being left transparent, because
    # dilation had swallowed them whole and there was no surviving seed to
    # grow back from.
    outside = outside.filter(ImageFilter.MaxFilter(2 * seal + 1))
    outside = ImageChops.subtract(outside, stroke)
    inner = ImageChops.subtract(
        Image.eval(closed, lambda v: 255 - v), outside)

    out = Image.new("RGBA", src.size, (255, 255, 255, 0))
    out.putalpha(inner)                        # white fill
    out = Image.alpha_composite(out, src)      # black strokes on top

    # Transparent pixels carry RGB too, and PIL does not premultiply on
    # resize: leaving them black would drag a dark fringe around the white
    # edges on the way down to `px`.
    rgb = out.convert("RGB")
    white = Image.new("RGB", src.size, (255, 255, 255))
    a = out.getchannel("A")
    flat = Image.composite(rgb, white, a.point(lambda v: 255 if v > 0 else 0))
    flat.putalpha(a)
    return flat.resize((px, px), Image.LANCZOS)


SRC_PX = 716


def menubar_template(px):
    """Menu bar icons use the ALPHA channel only — macOS recolours them for
    light and dark bars.

    This used to take the alpha of the line art, which made the icon read
    as an outline: thin strokes on nothing. The manager header shows a
    FILLED corgi, and the two should match. So the mask here is the
    enclosed fill instead, with the strokes knocked back OUT of it — the
    same shape, rendered as a solid silhouette with the eyes, nose and
    blaze as gaps.

    The knockouts are eroded before downsampling. A stroke that is a
    fraction of a pixel wide at 18pt simply vanishes, and the icon
    collapses into an unreadable blob.
    """
    big = filled_corgi(SRC_PX)
    alpha = big.getchannel("A").point(lambda v: 255 if v > 128 else 0)
    lum = big.convert("L")
    # White fill stays; black strokes drop out.
    mask = ImageChops.multiply(alpha, lum.point(lambda v: 255 if v > 140 else 0))
    # MinFilter erodes the white, which is what widens the knockouts.
    grow = max(1, round(SRC_PX / px / 6))
    mask = mask.filter(ImageFilter.MinFilter(grow * 2 + 1))
    mask = mask.resize((px, px), Image.LANCZOS)
    mask = mask.point(lambda v: min(255, int(v * 1.2)))
    out = Image.new("RGBA", (px, px), (255, 255, 255, 0))
    out.putalpha(mask)
    return out


def main():
    n = write_icns(os.path.join(HERE, "AppIcon.icns"))
    app_icon(1024).save(os.path.join(HERE, "icon-1024.png"))

    # Manager header: filled white with black strokes. 256px is ample for a
    # 48pt slot and keeps the base64 blob embedded in init.lua small.
    filled_corgi(256).save(os.path.join(HERE, "xl-corgi.png"))

    menubar_template(18).save(os.path.join(HERE, "menubar.png"))
    menubar_template(36).save(os.path.join(HERE, "menubar@2x.png"))

    print("AppIcon.icns   %d bytes" % n)
    for f in ("icon-1024.png", "xl-corgi.png", "menubar.png", "menubar@2x.png"):
        print("%-14s %d bytes" % (f, os.path.getsize(os.path.join(HERE, f))))


if __name__ == "__main__":
    main()
