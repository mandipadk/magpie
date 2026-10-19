#!/usr/bin/env python3
"""Draws Magpie's app icon: the magpie from magpie.svg (ink, white belly, jade
wing) perched on a white tile. Writes the macOS and iOS icon sets.

    python3 apps/art/icon.py      (needs rsvg-convert)
"""
import io, json, pathlib, subprocess
from PIL import Image, ImageDraw, ImageFilter

S = 1024
HERE = pathlib.Path(__file__).parent
TILE = (246, 246, 244)
JADE = (47, 156, 114)


def art(size):
    png = subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(HERE / "magpie.svg")],
                         check=True, capture_output=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


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
    tile = Image.new("RGBA", (S, S), TILE + (255,))
    base.paste(tile, (0, 0), mask)
    a = art(S - 2 * inset - 120)
    base.alpha_composite(a, (inset + 60, inset + 60))
    return base


def ios_icon():
    # iOS: full-bleed square, the system rounds it
    base = Image.new("RGBA", (S, S), TILE + (255,))
    a = art(800)
    base.alpha_composite(a, (112, 112))
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
