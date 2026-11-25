#!/usr/bin/env python3
"""Iris's icon after the ring on Iris's website (site/index.html, .ring):
a clear liquid-glass annulus, the spectrum gathered towards its lower rim
(red, orange, yellow, green, cyan, blue and back to red through warm white;
never purple), a thin white rim on top and a soft glow, on a near-colourless
tile. Pure SVG (no embedded bitmaps): SVG has no conic gradient, so the
band is 360 one-degree wedges, blurred and masked like the site's
.ring__band. python3 make.py (needs /usr/bin/rsvg-convert, Pillow and numpy)."""
import math, os, subprocess
import numpy as np
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))

# the site's --spectrum (style.css): angle from the top, clockwise
SPECTRUM = [(0, "FF3B30"), (45, "FF9500"), (90, "FFD60A"), (140, "34C759"),
            (190, "32D2F5"), (235, "0A84FF"), (300, "FFF4E2"), (360, "FF3B30")]


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def spectrum_at(a):
    a %= 360
    for (a0, c0), (a1, c1) in zip(SPECTRUM, SPECTRUM[1:]):
        if a0 <= a <= a1:
            t = (a - a0) / (a1 - a0)
            return "#%02X%02X%02X" % tuple(round(x + (y - x) * t) for x, y in zip(rgb(c0), rgb(c1)))
    raise ValueError(a)


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def pt(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.sin(a), cy - r * math.cos(a)


def wedges(cx, cy, r0, r1, rot=0, step=1):
    """the conic gradient: one annular wedge per degree, a hair wider so no seams show"""
    out = []
    for d in range(0, 360, step):
        a0, a1 = d - 0.35, d + step + 0.35
        x0, y0 = pt(cx, cy, r1, a0)
        x1, y1 = pt(cx, cy, r1, a1)
        x2, y2 = pt(cx, cy, r0, a1)
        x3, y3 = pt(cx, cy, r0, a0)
        out.append(f'<path d="M{f(x0)} {f(y0)}L{f(x1)} {f(y1)}L{f(x2)} {f(y2)}L{f(x3)} {f(y3)}Z" '
                   f'fill="{spectrum_at(d + step / 2 - rot)}"/>')
    return "\n      ".join(out)


def squircle(x0, y0, w, h, r, n=2.6, steps=24):
    """a rounded rectangle with continuous corners (|x|^n + |y|^n = 1)"""
    pts = []
    corners = [(x0 + w - r, y0 + r, 0), (x0 + w - r, y0 + h - r, 90),
               (x0 + r, y0 + h - r, 180), (x0 + r, y0 + r, 270)]
    for cx, cy, start in corners:
        for i in range(steps + 1):
            t = math.radians(start - 90 + 90 * i / steps)
            c, s = math.cos(t), math.sin(t)
            px = cx + r * math.copysign(abs(c) ** (2 / n), c)
            py = cy + r * math.copysign(abs(s) ** (2 / n), s)
            pts.append((px, py))
    return "M" + "L".join(f"{f(x)} {f(y)}" for x, y in pts) + "Z"


def css_linear(cx, cy, size, deg):
    """endpoints of a CSS linear-gradient(<deg>) over a size×size box"""
    a = math.radians(deg)
    dx, dy = math.sin(a), -math.cos(a)
    half = (abs(size * dx) + abs(size * dy)) / 2
    return (f'x1="{f(cx - dx * half)}" y1="{f(cy - dy * half)}" '
            f'x2="{f(cx + dx * half)}" y2="{f(cy + dy * half)}"')


def ring(id, cx, cy, D, small=False, glow=True, shadow=True):
    """the website's ring (.ring: __glow, __band, __glass, __rim) in a D×D box.
    small: the 48 and 64 pixel cut, a thicker, brighter band and no fine lines"""
    R = D / 2
    k = D / 336  # the site's ring is 336 px wide at its largest
    p = id
    defs, body = [], []
    # the band's place in the glass: closest-side radial mask
    band_stops = ((0.52, 0), (0.62, 1), (0.92, 1), (0.99, 0)) if small else \
                 ((0.60, 0), (0.72, 1), (0.86, 1), (0.97, 0))
    defs.append(f'<radialGradient id="{p}bandR" gradientUnits="userSpaceOnUse" cx="{f(cx)}" cy="{f(cy)}" r="{f(R)}">'
                + "".join(f'<stop offset="{o}" stop-color="#fff" stop-opacity="{a}"/>' for o, a in band_stops)
                + "</radialGradient>")
    # the light gathers at the lower rim: the site's linear-gradient(170deg, .12 18%, .55 50%, 1 82%)
    lin = ((0.18, 0.40), (0.5, 0.75), (0.82, 1)) if small else ((0.18, 0.12), (0.5, 0.55), (0.82, 1))
    defs.append(f'<linearGradient id="{p}bandL" gradientUnits="userSpaceOnUse" {css_linear(cx, cy, D, 170)}>'
                + "".join(f'<stop offset="{o}" stop-color="#fff" stop-opacity="{a}"/>' for o, a in lin)
                + "</linearGradient>")
    defs.append(f'<mask id="{p}maskR" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
                f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(R)}" fill="url(#{p}bandR)"/></mask>')
    defs.append(f'<mask id="{p}maskL" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
                f'<rect width="512" height="512" fill="url(#{p}bandL)"/></mask>')
    blur = (4.5 if small else 10) * k
    defs.append(f'<filter id="{p}blur" x="-20%" y="-20%" width="140%" height="140%" color-interpolation-filters="sRGB">'
                f'<feGaussianBlur stdDeviation="{f(blur)}"/></filter>')
    # the glass annulus, 56% to 97% of the box
    defs.append(f'<mask id="{p}annulus" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
                f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(R * 0.97)}" fill="#fff"/>'
                f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(R * 0.56)}" fill="#000"/></mask>')
    glass_stops = ((0.555, 0), (0.56, 0), (0.60, .45), (0.72, .04), (0.86, .02), (0.97, .5), (0.98, 0))
    if small:
        glass_stops = ((0.555, 0), (0.56, 0), (0.59, .7), (0.66, .08), (0.90, .04), (0.97, .65), (0.98, 0))
    defs.append(f'<radialGradient id="{p}glassR" gradientUnits="userSpaceOnUse" cx="{f(cx)}" cy="{f(cy)}" r="{f(R)}">'
                + "".join(f'<stop offset="{o}" stop-color="#fff" stop-opacity="{a}"/>' for o, a in glass_stops)
                + "</radialGradient>")
    defs.append(f'<linearGradient id="{p}glassL" gradientUnits="userSpaceOnUse" {css_linear(cx, cy, D, 160)}>'
                '<stop offset="0" stop-color="#fff" stop-opacity=".55"/>'
                '<stop offset=".45" stop-color="#fff" stop-opacity="0"/>'
                '<stop offset="1" stop-color="#fff" stop-opacity=".15"/></linearGradient>')

    if glow:
        # ambient light the ring throws on the tile: the band again, wide and faint
        g = D * 1.16
        defs.append(f'<radialGradient id="{p}glowR" gradientUnits="userSpaceOnUse" cx="{f(cx)}" cy="{f(cy)}" r="{f(g / 2)}">'
                    '<stop offset=".38" stop-color="#fff" stop-opacity="0"/>'
                    '<stop offset=".62" stop-color="#fff" stop-opacity="1"/>'
                    '<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>')
        defs.append(f'<mask id="{p}glowM" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
                    f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(g / 2)}" fill="url(#{p}glowR)"/></mask>')
        defs.append(f'<filter id="{p}glowB" x="-50%" y="-50%" width="200%" height="200%" color-interpolation-filters="sRGB">'
                    f'<feGaussianBlur stdDeviation="{f(30 * k)}"/></filter>')
        body.append(f'<!-- the glow --><g opacity=".24" filter="url(#{p}glowB)"><g mask="url(#{p}glowM)">\n      '
                    + wedges(cx, cy, 0, g / 2, step=2) + "\n    </g></g>")
    if shadow:
        # box-shadow: 0 24px 64px rgba(0,0,0,.10), outside the ring only
        defs.append(f'<filter id="{p}shB" x="-50%" y="-50%" width="200%" height="200%">'
                    f'<feGaussianBlur stdDeviation="{f((12 if small else 26) * k)}"/></filter>')
        defs.append(f'<mask id="{p}outside" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
                    f'<rect width="512" height="512" fill="#fff"/>'
                    f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(R * 0.97)}" fill="#000"/>'
                    f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(R * 0.56)}" fill="#fff"/></mask>')
        ro, ri, sy = R * 0.97, R * 0.56, cy + 20 * k
        annulus = (f"M{f(cx - ro)} {f(sy)}a{f(ro)} {f(ro)} 0 1 0 {f(2 * ro)} 0a{f(ro)} {f(ro)} 0 1 0 {f(-2 * ro)} 0Z"
                   f"M{f(cx - ri)} {f(sy)}a{f(ri)} {f(ri)} 0 1 0 {f(2 * ri)} 0a{f(ri)} {f(ri)} 0 1 0 {f(-2 * ri)} 0Z")
        body.append(f'<!-- its shadow --><g mask="url(#{p}outside)"><path d="{annulus}" fill-rule="evenodd" '
                    f'fill="#000000" fill-opacity="{".16" if small else ".12"}" filter="url(#{p}shB)"/></g>')
    body.append(f'<!-- the band --><g opacity="{"1" if small else ".95"}" mask="url(#{p}maskL)"><g mask="url(#{p}maskR)">'
                f'<g filter="url(#{p}blur)">\n      '
                + wedges(cx, cy, R * 0.45, R * 1.0) + "\n    </g></g></g>")
    body.append(f'<!-- the glass --><g mask="url(#{p}annulus)">'
                f'<rect x="{f(cx - R)}" y="{f(cy - R)}" width="{f(D)}" height="{f(D)}" fill="url(#{p}glassR)"/>'
                f'<rect x="{f(cx - R)}" y="{f(cy - R)}" width="{f(D)}" height="{f(D)}" fill="url(#{p}glassL)"/></g>')
    # the rim (.ring__rim, the site's own 200×200 drawing)
    s = D / 200
    defs.append(f'<linearGradient id="{p}rimOuter" x1="0" y1="0" x2="0" y2="1">'
                '<stop offset="0" stop-color="#fff" stop-opacity=".95"/>'
                '<stop offset=".45" stop-color="#fff" stop-opacity=".15"/>'
                '<stop offset="1" stop-color="#fff" stop-opacity=".55"/></linearGradient>')
    defs.append(f'<linearGradient id="{p}rimInner" x1="0" y1="0" x2="0" y2="1">'
                '<stop offset="0" stop-color="#000" stop-opacity=".2"/>'
                '<stop offset=".5" stop-color="#fff" stop-opacity=".1"/>'
                '<stop offset="1" stop-color="#fff" stop-opacity=".9"/></linearGradient>')
    defs.append(f'<radialGradient id="{p}spec" cx=".32" cy=".18" r=".5">'
                '<stop offset="0" stop-color="#fff" stop-opacity=".95"/>'
                '<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>')
    sw = 1.4 * (2.4 if small else 1.5)
    rim = [f'<circle cx="100" cy="100" r="97" fill="none" stroke="url(#{p}rimOuter)" stroke-width="{f(sw)}"/>',
           f'<circle cx="100" cy="100" r="55" fill="none" stroke="url(#{p}rimInner)" stroke-width="{f(sw)}"/>']
    if small:
        # a faint cool line round the outside, so the clear glass keeps its edge on a light tile
        rim.insert(0, '<circle cx="100" cy="100" r="98.6" fill="none" stroke="#000" stroke-opacity=".16" stroke-width="2"/>')
        rim.append(f'<path d="M36 64 A72 72 0 0 1 110 25" fill="none" stroke="url(#{p}spec)" stroke-width="12" stroke-linecap="round"/>')
    else:
        rim.insert(0, '<circle cx="100" cy="100" r="98.2" fill="none" stroke="#000" stroke-opacity=".10" stroke-width="1.2"/>')
        rim.append(f'<path d="M40 58 A72 72 0 0 1 112 25" fill="none" stroke="url(#{p}spec)" stroke-width="9" stroke-linecap="round" opacity=".9"/>')
        rim.append('<path d="M152 150 A68 68 0 0 1 124 165" fill="none" stroke="#fff" stroke-opacity=".6" stroke-width="3" stroke-linecap="round"/>')
    body.append(f'<!-- the rim --><g transform="translate({f(cx - R)} {f(cy - R)}) scale({f(s)})">'
                + "".join(rim) + "</g>")
    return defs, body


HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">\n'
        "  <!-- Iris's icon: a clear glass ring, the spectrum gathered at its lower rim, on a near-colourless tile.\n"
        "       Tulip Labs, GPL-3.0. Drawn by make.py after the ring on Iris's website; never purple. -->\n")


def tile_svg(small=False):
    # the tile: 432 of 512 wide (GNOME's 128 grid: 108 wide), its slab edge and a soft shadow
    X, Y, W, H, R = 40, 34, 432, 424, 92
    face = squircle(X, Y, W, H, R)
    edge = squircle(X, Y + 10, W, H, R)
    cx, cy = X + W / 2, Y + H / 2
    D = 340 if small else 308
    defs, body = ring("r", cx, cy, D, small=small, glow=not small)
    out = [HEAD, "  <defs>\n"]
    out.append('    <linearGradient id="face" x1="0" y1="0" x2="0" y2="1">'
               '<stop offset="0" stop-color="#F5F6F8"/><stop offset="1" stop-color="#ECEEF2"/></linearGradient>\n')
    out.append('    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
               '<stop offset="0" stop-color="#fff" stop-opacity=".9"/><stop offset=".08" stop-color="#fff" stop-opacity="0"/></linearGradient>\n')
    out.append('    <filter id="tileSh" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter>\n')
    out.append('    <filter id="tileSh2" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.5"/></filter>\n')
    out.append(f'    <clipPath id="faceClip"><path d="{face}"/></clipPath>\n')
    out += ["    " + d + "\n" for d in defs]
    out.append("  </defs>\n")
    out.append(f'  <!-- shadow and slab -->\n  <path d="{squircle(X + 6, Y + 18, W - 12, H - 4, R)}" fill="#000000" fill-opacity=".20" filter="url(#tileSh)"/>\n')
    out.append(f'  <path d="{edge}" fill="#000000" fill-opacity=".22" filter="url(#tileSh2)"/>\n')
    out.append(f'  <path d="{edge}" fill="#D9DCE3"/>\n')
    out.append(f'  <!-- the face -->\n  <path d="{face}" fill="url(#face)"/>\n')
    out.append(f'  <path d="{face}" fill="none" stroke="url(#sheen)" stroke-width="3"/>\n')
    out.append('  <g clip-path="url(#faceClip)">\n    ' + "\n    ".join(body) + "\n  </g>\n</svg>\n")
    return "".join(out)


def bleed_svg(D=320, back=True, small=False):
    """full bleed: the face edge to edge, for places that cut their own shape
    (back=False: only the ring, for Android's adaptive foreground)"""
    defs, body = ring("r", 256, 256, D, small=small, glow=True)
    out = [HEAD, "  <defs>\n"]
    out.append('    <linearGradient id="face" x1="0" y1="0" x2="0" y2="1">'
               '<stop offset="0" stop-color="#F5F6F8"/><stop offset="1" stop-color="#ECEEF2"/></linearGradient>\n')
    out += ["    " + d + "\n" for d in defs]
    out.append("  </defs>\n")
    if back:
        out.append('  <rect width="512" height="512" fill="url(#face)"/>\n')
    out.append("  " + "\n  ".join(body) + "\n</svg>\n")
    return "".join(out)


def render(svg_path, png_path, size):
    subprocess.run(["/usr/bin/rsvg-convert", "-w", str(size), "-h", str(size), "-o", png_path, svg_path], check=True)


def render_down(svg_path, png_path, size):
    """small sizes: draw at 4× and filter down, crisper than rsvg's own sampling of the blurs"""
    tmp = png_path + ".tmp.png"
    render(svg_path, tmp, size * 4)
    # filtered with premultiplied alpha, so no colour bleeds out of the see-through edge
    im = Image.open(tmp).convert("RGBA").convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")
    # the see-through rim of the tile and its shadow are grey: rounding at low alpha
    # must not leave a tint there (and never a purple one)
    a = np.asarray(im).copy()
    thin = a[..., 3] < 160
    a[thin, :3] = a[thin, :3].mean(axis=-1, keepdims=True).round().astype(np.uint8)
    im = Image.fromarray(a, "RGBA")
    im.save(png_path, optimize=True)
    os.remove(tmp)


if __name__ == "__main__":
    j = lambda *a: os.path.join(here, *a)
    with open(j("iris.svg"), "w") as fh:
        fh.write(tile_svg())
    with open(j("iris-fullbleed.svg"), "w") as fh:
        fh.write(bleed_svg())
    tmpdir = j(".build")
    os.makedirs(tmpdir, exist_ok=True)
    with open(os.path.join(tmpdir, "small.svg"), "w") as fh:
        fh.write(tile_svg(small=True))
    # Android's adaptive foreground: the ring 52 of 108 dp (well inside the 66 dp safe circle),
    # on the tile's face, edge to edge (icon_back is the same colour, for the moment before it draws)
    with open(os.path.join(tmpdir, "fg.svg"), "w") as fh:
        fh.write(bleed_svg(D=512 * 52 / 108 / 0.97))
    with open(os.path.join(tmpdir, "fg-small.svg"), "w") as fh:
        fh.write(bleed_svg(D=512 * 52 / 108 / 0.97, small=True))
    for n in (128, 256, 512):
        render_down(j("iris.svg"), j(f"iris-{n}.png"), n)
    for n in (48, 64):
        render_down(os.path.join(tmpdir, "small.svg"), j(f"iris-{n}.png"), n)
    for d, k in (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)):
        p = j("android", f"mipmap-{d}")
        os.makedirs(p, exist_ok=True)
        n = round(48 * k)
        render_down(os.path.join(tmpdir, "small.svg") if n <= 96 else j("iris.svg"), os.path.join(p, "ic_launcher.png"), n)
        n = round(108 * k)
        render_down(os.path.join(tmpdir, "fg-small.svg" if k <= 1 else "fg.svg"), os.path.join(p, "ic_launcher_foreground.png"), n)
    for x in os.listdir(tmpdir):
        os.remove(os.path.join(tmpdir, x))
    os.rmdir(tmpdir)
    print("icon_back #F2F3F5")
