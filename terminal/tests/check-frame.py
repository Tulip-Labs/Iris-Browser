#!/usr/bin/env python3
"""Checks the picture iris-terminal --dump-frame wrote (a PAM, RGB_ALPHA)
against the layout in the --dump-state file, for tests/emit.sh's screen:
 - the corners are clear (the glass is rounded), the middle is translucent glass
 - the two cells of each colour block (row 1) are exactly red, green and blue
 - the red 'red' text (row 0) has pixels of the theme's red
 - the text is not smeared: whole pixels (some pixel of the text is full coverage)
usage: check-frame.py FRAME.pam STATE.txt"""
import re, sys

frame, state = sys.argv[1:3]
d = open(frame, "rb").read()
hdr_end = d.index(b"ENDHDR\n") + 7
hdr = d[:hdr_end].decode()
w = int(re.search(r"WIDTH (\d+)", hdr).group(1))
h = int(re.search(r"HEIGHT (\d+)", hdr).group(1))
px = d[hdr_end:]
assert len(px) == w * h * 4, (len(px), w, h)
lay = re.search(r"layout: ox=(\d+) oy=(\d+) cell=(\d+)x(\d+) pixel=(\d+)x(\d+)", open(state).read())
ox, oy, cw, ch, pw, ph = map(int, lay.groups())
assert (pw, ph) == (w, h), ((pw, ph), (w, h))


def at(x, y):
    i = (y * w + x) * 4
    return tuple(px[i:i + 4])


print(f"frame {w}x{h}, cell {cw}x{ch}, origin {ox},{oy}")
assert at(0, 0)[3] == 0, f"the top left corner is not clear: {at(0, 0)}"
assert at(w - 1, h - 1)[3] == 0, f"the bottom right corner is not clear: {at(w - 1, h - 1)}"
mid = at(w // 2, h - 4)
print("glass in the bottom padding:", mid)
assert 60 <= mid[3] <= 255, f"the glass is not translucent-to-solid: {mid}"


def cell_center(col, row):
    return at(ox + col * cw + cw // 2, oy + row * ch + ch // 2)


blocks = [(0, (255, 0, 0)), (1, (255, 0, 0)), (2, (0, 255, 0)), (3, (0, 255, 0)), (4, (0, 0, 255)), (5, (0, 0, 255))]
for col, rgb in blocks:
    got = cell_center(col, 1)
    assert got[:3] == rgb and got[3] == 255, f"cell {col},1 is {got}, wanted {rgb}"
print("colour blocks: exact red, green, blue (6 cells)")

# 'red' is drawn in the theme's red (palette 1): find its full-coverage pixels
want = (0xf2, 0x70, 0x6f)
n = 0
for y in range(oy, oy + ch):
    for x in range(ox, ox + 3 * cw):
        p = at(x, y)
        if p[3] == 255 and all(abs(p[i] - want[i]) <= 3 for i in range(3)):
            n += 1
print("pixels of the theme red in 'red':", n)
assert n >= 8, "the red text is not there"
# the text of row 2 ("wide|", after two wide characters that may have no font here):
# bright pixels on the dark glass (the glass itself is below 30)
ink = sum(1 for y in range(oy + 2 * ch, oy + 3 * ch) for x in range(ox, ox + 12 * cw) if max(at(x, y)[:3]) > 90)
print("bright pixels in row 2:", ink)
assert ink >= 15, "no text in row 2"
# whole pixels: a vertical stem of the '|' at the end of row 1's text is crisp (an exact full-coverage pixel)
full = sum(1 for y in range(oy + 2 * ch, oy + 3 * ch) for x in range(ox, ox + 12 * cw) if at(x, y)[3] == 255 and min(at(x, y)[:3]) > 200)
print("full-coverage pixels in row 2:", full)
assert full >= 3, "the text is blurred: no pixel is fully covered"
print("frame ok")
