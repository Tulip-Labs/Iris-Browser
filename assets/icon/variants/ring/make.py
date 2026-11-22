#!/usr/bin/env python3
"""Iris's icon from the ring concept (source.jpg): the white glass tile with
the clear ring, light entering top left and leaving as a rainbow. The tile
is cut from its backdrop, given its own soft shadow, and drawn at every size
Iris uses. python3 make.py (needs Pillow and numpy)."""
import base64, io, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

here = os.path.dirname(os.path.abspath(__file__))
src = Image.open(os.path.join(here, "source.jpg")).convert("RGB")

# the tile in source.jpg: its face and the slab's edge under it
X0, Y0, X1, Y1, R = 443, 118, 963, 649, 100
# the ring's centre and outer diameter
CX, CY, RING = 703, 383, 425
SS = 4  # supersampling for clean edges


def squircle(w, h, r, ss=SS):
    """a rounded rectangle with continuous (squircle-like) corners"""
    W, H, Rr = w * ss, h * ss, r * ss
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32) + 0.5
    dx = np.maximum(np.maximum(Rr - xx, xx - (W - Rr)), 0) / Rr
    dy = np.maximum(np.maximum(Rr - yy, yy - (H - Rr)), 0) / Rr
    inside = (dx ** 2.6 + dy ** 2.6) <= 1.0
    m = Image.fromarray((inside * 255).astype(np.uint8))
    return m.resize((w, h), Image.LANCZOS)


tile = src.crop((X0, Y0, X1, Y1)).convert("RGBA")
tile.putalpha(squircle(X1 - X0, Y1 - Y0, R))


def icon(size):
    """the tile on a transparent square, with a soft shadow under it"""
    S = max(size, 512) * 2
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tw = round(S * 0.86)
    th = round(tw * tile.height / tile.width)
    t = tile.resize((tw, th), Image.LANCZOS)
    ox, oy = (S - tw) // 2, (S - th) // 2 - round(S * 0.012)
    # shadow: a wide soft one and a close one, cool grey
    for blur, alpha, dy in ((S * 0.028, 70, S * 0.022), (S * 0.008, 60, S * 0.008)):
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        a = Image.new("L", (S, S), 0)
        a.paste(t.getchannel("A"), (ox, oy + round(dy)))
        a = a.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: v * alpha // 255)
        sh.putalpha(a)
        sh = Image.merge("RGBA", (*Image.new("RGB", (S, S), (40, 36, 64)).split(), a))
        canvas = Image.alpha_composite(canvas, sh)
    canvas.alpha_composite(t, (ox, oy))
    out = canvas.resize((size, size), Image.LANCZOS)
    if size <= 64:
        out = out.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=1))
    return out


def face_colour():
    """the tile's own white, where neither ring nor rainbow reaches"""
    a = np.asarray(src).astype(float)
    pts = [a[130:150, 640:770], a[200:260, 455:475], a[200:260, 935:952]]
    return tuple(int(round(v)) for v in np.concatenate([p.reshape(-1, 3) for p in pts]).mean(0))


def foreground(size):
    """Android's adaptive layer: the ring 62 of 108 dp, the tile's face
    around it; the launcher's mask cuts the shape"""
    side = RING * 108 / 62
    box = (CX - side / 2, CY - side / 2, CX + side / 2, CY + side / 2)
    S = size * 2
    sx = S / side
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    t = tile.resize((round(tile.width * sx), round(tile.height * sx)), Image.LANCZOS)
    canvas.alpha_composite(t, (round((X0 - box[0]) * sx), round((Y0 - box[1]) * sx)))
    return canvas.resize((size, size), Image.LANCZOS)


def svg(png):
    b = io.BytesIO()
    png.save(b, "PNG", optimize=True)
    data = base64.b64encode(b.getvalue()).decode()
    return ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            'viewBox="0 0 512 512" width="512" height="512">\n'
            '  <!-- Iris\'s icon: a clear glass ring on a white tile, light entering and leaving as a rainbow. '
            'Tulip Labs, GPL-3.0. Made from source.jpg by make.py. -->\n'
            f'  <image width="512" height="512" xlink:href="data:image/png;base64,{data}"/>\n</svg>\n')


if __name__ == "__main__":
    big = icon(512)
    for n in (48, 64, 128, 256, 512):
        (big if n == 512 else icon(n)).save(os.path.join(here, f"iris-{n}.png"), optimize=True)
    with open(os.path.join(here, "iris.svg"), "w") as f:
        f.write(svg(big))
    # full bleed: the face alone, edge to edge (for places that cut their own shape)
    full = tile.crop((40, 40, tile.width - 40, tile.height - 51)).resize((512, 512), Image.LANCZOS)
    with open(os.path.join(here, "iris-fullbleed.svg"), "w") as f:
        f.write(svg(full))
    for d, k in (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)):
        p = os.path.join(here, "android", f"mipmap-{d}")
        os.makedirs(p, exist_ok=True)
        icon(round(48 * k)).save(os.path.join(p, "ic_launcher.png"), optimize=True)
        foreground(round(108 * k)).save(os.path.join(p, "ic_launcher_foreground.png"), optimize=True)
    print("icon_back #%02X%02X%02X" % face_colour())
