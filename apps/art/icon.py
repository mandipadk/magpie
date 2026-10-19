#!/usr/bin/env python3
"""Draws Magpie's app icon: an ink squircle, a white cloud, and a long jade
tail (the magpie's) sweeping out of it. Writes the macOS and iOS icon sets.

    python3 apps/art/icon.py
"""
import json, math, pathlib
from PIL import Image, ImageDraw, ImageFilter

S = 1024
HERE = pathlib.Path(__file__).parent
INK = (14, 14, 15)
WHITE = (246, 246, 244)
JADE = (47, 156, 114)


def squircle_mask(size, inset, n=5.0):
    m = Image.new("L", (size, size), 0)
    px = m.load()
    c = size / 2
    r = c - inset
    for y in range(size):
        for x in range(size):
            dx, dy = abs(x + 0.5 - c) / r, abs(y + 0.5 - c) / r
            v = dx ** n + dy ** n
            if v <= 1:
                px[x, y] = 255
    return m


def art(scale=4):
    W = S * scale
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = W / 1024
    # tail: the magpie's long tail, a tapering wedge out of the cloud's
    # lower right toward the corner
    x0, y0, x1, y1 = 640, 600, 850, 800
    for i in range(400):
        t = i / 399
        x = x0 + (x1 - x0) * t
        y = y0 + (y1 - y0) * t + 30 * math.sin(math.pi * t)
        w = (44 - 34 * t) * k
        d.ellipse([x * k - w, y * k - w, x * k + w, y * k + w], fill=JADE)
    # cloud: three circles on a rounded base
    def circ(cx, cy, r):
        d.ellipse([(cx - r) * k, (cy - r) * k, (cx + r) * k, (cy + r) * k], fill=WHITE)
    circ(372, 520, 128)
    circ(530, 440, 170)
    circ(668, 540, 116)
    d.rounded_rectangle([244 * k, 520 * k, 784 * k, 656 * k], radius=68 * k, fill=WHITE)
    return img.resize((S, S), Image.LANCZOS)


def mac_icon():
    # macOS: the shape sits inside a 1024 canvas with a margin and a soft shadow
    inset = 100
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, S - inset, S - inset], radius=185, fill=255)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (0, 0), mask)
    shadow = shadow.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -12)).filter(ImageFilter.GaussianBlur(18))
    base.alpha_composite(shadow)
    tile = Image.new("RGBA", (S, S), INK + (255,))
    base.paste(tile, (0, 0), mask)
    a = art().resize((S - 2 * inset - 40, S - 2 * inset - 40), Image.LANCZOS)
    base.alpha_composite(a, (inset + 20, inset + 20))
    return base


def ios_icon():
    # iOS: full-bleed square, the system rounds it
    base = Image.new("RGBA", (S, S), INK + (255,))
    a = art().resize((880, 880), Image.LANCZOS)
    base.alpha_composite(a, (72, 72))
    return base.convert("RGB")


def write_mac(dst):
    dst.mkdir(parents=True, exist_ok=True)
    icon = mac_icon()
    images = []
    for pt in (16, 32, 128, 256, 512):
        for sc in (1, 2):
            px = pt * sc
            name = f"icon_{pt}x{pt}{'@2x' if sc == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(dst / name)
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{sc}x", "filename": name})
    (dst / "Contents.json").write_text(json.dumps({"images": images, "info": {"version": 1, "author": "xcode"}}, indent=2))


def write_ios(dst):
    dst.mkdir(parents=True, exist_ok=True)
    ios_icon().save(dst / "icon-1024.png")
    (dst / "Contents.json").write_text(json.dumps({"images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-1024.png"}], "info": {"version": 1, "author": "xcode"}}, indent=2))


def write_accent(dst):
    dst.mkdir(parents=True, exist_ok=True)
    def comp(rgb):
        return {"color-space": "srgb", "components": {"red": f"{rgb[0]/255:.3f}", "green": f"{rgb[1]/255:.3f}", "blue": f"{rgb[2]/255:.3f}", "alpha": "1.000"}}
    (dst / "Contents.json").write_text(json.dumps({"colors": [
        {"idiom": "universal", "color": comp((29, 122, 88))},
        {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(JADE)},
    ], "info": {"version": 1, "author": "xcode"}}, indent=2))


if __name__ == "__main__":
    root = HERE.parent
    for app in ("mac", "ios"):
        cat = root / app / "App" / "Assets.xcassets"
        cat.mkdir(parents=True, exist_ok=True)
        (cat / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"}}))
        (write_mac if app == "mac" else write_ios)(cat / "AppIcon.appiconset")
        write_accent(cat / "AccentColor.colorset")
    mac_icon().save(HERE / "icon-mac.png")
    ios_icon().save(HERE / "icon-ios.png")
