#!/usr/bin/env python3
"""Draws the Paint app icon and builds AppIcon.icns.

Two crossing paint swooshes — warm over cool — glowing on a near-black plate.
Everything is parametric: cubic Beziers stamped with tapering discs, drawn at
3x and downsampled, so it stays clean all the way down to 16px.
"""
import math, os, subprocess
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 3
W = S * SS

# Colour stops travelling along each swoosh.
WARM = [(124, 47, 247), (247, 37, 133), (255, 94, 58), (255, 194, 40)]
COOL = [(0, 224, 255), (0, 168, 232), (56, 232, 168), (168, 255, 96)]


def multi_lerp(stops, t):
    t = min(max(t, 0.0), 1.0) * (len(stops) - 1)
    i = min(int(t), len(stops) - 2)
    f = t - i
    a, b = stops[i], stops[i + 1]
    return tuple(int(round(a[k] + (b[k] - a[k]) * f)) for k in range(3))


def bezier(p0, p1, p2, p3, t):
    u = 1 - t
    return (u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1])


def stamp(draw, x, y, r, color, alpha=255):
    draw.ellipse([x - r, y - r, x + r, y + r], fill=color + (alpha,))


def swoosh(layer, ctrl, stops, width, samples=900, radius_scale=1.0,
           alpha=255, color_override=None, offset=(0, 0), taper=0.6):
    """Stamps discs along a cubic Bezier, fat in the middle, tapered at the ends."""
    d = ImageDraw.Draw(layer)
    for i in range(samples + 1):
        t = i / samples
        x, y = bezier(*ctrl, t)
        prof = math.sin(math.pi * t) ** taper
        r = width * 0.5 * prof * radius_scale
        if r < 0.5:
            continue
        c = color_override or multi_lerp(stops, t)
        stamp(d, x + offset[0], y + offset[1], r, c, alpha)


def perpendicular_offset(ctrl, t, dist):
    """Normal to the curve at t, for laying a highlight along one edge."""
    e = 0.001
    x0, y0 = bezier(*ctrl, max(0.0, t - e))
    x1, y1 = bezier(*ctrl, min(1.0, t + e))
    dx, dy = x1 - x0, y1 - y0
    n = math.hypot(dx, dy) or 1.0
    return (-dy / n * dist, dx / n * dist)


img = Image.new("RGBA", (W, W), (0, 0, 0, 0))

# --- Plate ------------------------------------------------------------------
margin = int(W * 0.085)
radius = int(W * 0.225)
plate_box = [margin, margin, W - margin, W - margin]

shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(
    [plate_box[0], plate_box[1] + int(W * 0.016),
     plate_box[2], plate_box[3] + int(W * 0.016)],
    radius=radius, fill=(0, 0, 0, 110))
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(W * 0.020)))

# Deep diagonal gradient, dark enough that the colours read as light.
grad = Image.new("RGB", (64, 64))
gd = ImageDraw.Draw(grad)
for y in range(64):
    for x in range(64):
        t = (x / 63 * 0.45 + y / 63 * 0.55)
        gd.point((x, y), fill=(int(16 + 22 * t), int(18 + 26 * t), int(30 + 46 * t)))
grad = grad.resize((W, W), Image.BICUBIC).convert("RGBA")
plate_mask = Image.new("L", (W, W), 0)
ImageDraw.Draw(plate_mask).rounded_rectangle(plate_box, radius=radius, fill=255)
img.paste(grad, (0, 0), plate_mask)

# --- Swooshes ---------------------------------------------------------------
# A long warm S sweeping corner to corner, crossed by a shorter cool arc.
warm_ctrl = [(W * 0.13, W * 0.82), (W * 0.30, W * 0.24),
             (W * 0.70, W * 0.88), (W * 0.87, W * 0.24)]
cool_ctrl = [(W * 0.24, W * 0.20), (W * 0.52, W * 0.44),
             (W * 0.46, W * 0.60), (W * 0.78, W * 0.84)]

glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
swoosh(glow, cool_ctrl, COOL, W * 0.20, radius_scale=1.5, alpha=120)
swoosh(glow, warm_ctrl, WARM, W * 0.22, radius_scale=1.5, alpha=140)
glow = glow.filter(ImageFilter.GaussianBlur(W * 0.030))
glow.putalpha(glow.split()[3].point(lambda a: int(a * 0.85)))
img.alpha_composite(Image.composite(glow, Image.new("RGBA", (W, W), (0, 0, 0, 0)),
                                    plate_mask))

strokes = Image.new("RGBA", (W, W), (0, 0, 0, 0))
# Cool stroke behind, warm in front. The two palettes are far enough apart
# that the crossing reads on its own; a dark rim only muddied it.
swoosh(strokes, cool_ctrl, COOL, W * 0.155, radius_scale=1.0)
swoosh(strokes, warm_ctrl, WARM, W * 0.165, radius_scale=1.0)

# Specular sheen along the upper edge of each stroke.
sheen = ImageDraw.Draw(strokes)
for ctrl, width in ((cool_ctrl, W * 0.155), (warm_ctrl, W * 0.165)):
    for i in range(600):
        t = i / 600
        x, y = bezier(*ctrl, t)
        ox, oy = perpendicular_offset(ctrl, t, -width * 0.33)
        prof = math.sin(math.pi * t) ** 0.9
        r = width * 0.095 * prof
        if r < 0.5:
            continue
        # Keep the sheen on the edge; a broad one desaturates the whole stroke.
        stamp(sheen, x + ox, y + oy, r, (255, 255, 255), int(62 * prof))

img.alpha_composite(Image.composite(strokes, Image.new("RGBA", (W, W), (0, 0, 0, 0)),
                                    plate_mask))

# --- Droplets ---------------------------------------------------------------
d = ImageDraw.Draw(img)
for (fx, fy, fr, color) in [(0.885, 0.185, 0.028, WARM[3]),
                            (0.930, 0.268, 0.015, WARM[3]),
                            (0.815, 0.885, 0.024, COOL[3]),
                            (0.752, 0.905, 0.013, COOL[3])]:
    x, y, r = W * fx, W * fy, W * fr
    d.ellipse([x - r, y - r, x + r, y + r], fill=color + (255,))
    hr = r * 0.34
    d.ellipse([x - r * 0.30 - hr, y - r * 0.34 - hr,
               x - r * 0.30 + hr, y - r * 0.34 + hr], fill=(255, 255, 255, 130))

# Glass highlight across the top of the plate.
gloss = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(gloss).ellipse(
    [margin - W * 0.14, margin - W * 0.46, W - margin + W * 0.14, margin + W * 0.30],
    fill=(255, 255, 255, 26))
img.alpha_composite(Image.composite(gloss, Image.new("RGBA", (W, W), (0, 0, 0, 0)),
                                    plate_mask))

# Hairline edge.
ImageDraw.Draw(img).rounded_rectangle(plate_box, radius=radius,
                                      outline=(255, 255, 255, 40),
                                      width=int(W * 0.0035))

img = img.resize((S, S), Image.LANCZOS)

out = os.path.dirname(os.path.abspath(__file__))
iconset = os.path.join(out, "build", "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for f in os.listdir(iconset):
    os.remove(os.path.join(iconset, f))
for size in (16, 32, 128, 256, 512):
    img.resize((size, size), Image.LANCZOS).save(
        os.path.join(iconset, "icon_%dx%d.png" % (size, size)))
    img.resize((size * 2, size * 2), Image.LANCZOS).save(
        os.path.join(iconset, "icon_%dx%d@2x.png" % (size, size)))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o",
                os.path.join(out, "build", "AppIcon.icns")], check=True)
img.save(os.path.join(out, "build", "AppIcon-preview.png"))
print("Wrote build/AppIcon.icns")
