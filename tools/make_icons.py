#!/usr/bin/env python3
"""Draws the iBox icon and launch images into res/ (needs Pillow)."""
import os
from PIL import Image, ImageDraw

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "res")


def gradient(size, top, bottom):
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        d.line([(0, y), (size[0], y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def icon(px):
    s = 4  # supersample
    big = gradient((px * s, px * s), (36, 64, 160), (12, 18, 40))
    d = ImageDraw.Draw(big)
    w = px * s
    # TV body
    m = w * 0.17
    d.rounded_rectangle([m, w * 0.24, w - m, w * 0.70], radius=w * 0.06, fill=(240, 244, 255))
    d.rounded_rectangle([m + w * 0.045, w * 0.285, w - m - w * 0.045, w * 0.655], radius=w * 0.035, fill=(18, 26, 52))
    # play triangle
    cx, cy, r = w * 0.5, w * 0.47, w * 0.1
    d.polygon([(cx - r * 0.7, cy - r), (cx - r * 0.7, cy + r), (cx + r, cy)], fill=(0, 164, 220))
    # stand
    d.rounded_rectangle([w * 0.42, w * 0.70, w * 0.58, w * 0.77], radius=w * 0.01, fill=(200, 208, 230))
    d.rounded_rectangle([w * 0.32, w * 0.76, w * 0.68, w * 0.80], radius=w * 0.02, fill=(200, 208, 230))
    return big.resize((px, px), Image.LANCZOS)


def launch(size):
    img = gradient(size, (20, 27, 46), (8, 11, 19))
    d = ImageDraw.Draw(img)
    logo = icon(int(size[0] * 0.28))
    img.paste(logo, ((size[0] - logo.width) // 2, (size[1] - logo.height) // 2 - size[1] // 20))
    return img


if __name__ == "__main__":
    icon(57).save(os.path.join(RES, "Icon.png"))
    icon(114).save(os.path.join(RES, "Icon@2x.png"))
    launch((320, 480)).save(os.path.join(RES, "Default.png"))
    launch((640, 960)).save(os.path.join(RES, "Default@2x.png"))
    print("icons written to", os.path.abspath(RES))
