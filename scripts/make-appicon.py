#!/usr/bin/env python3
"""Regenerate AppIcon.appiconset from a full-bleed 1024 master.

macOS App Store Connect already insets macOS icons by the standard margin, so the
artwork must be full-bleed: the rounded square touches all four edges of the
canvas and only the area outside the rounded corners is transparent. This script
takes the existing artwork, discards the baked-in drop shadow, crops to the solid
rounded square, scales it to fill 1024x1024, and writes every required size.
"""
import sys
from pathlib import Path
from PIL import Image

ICONSET = Path(__file__).resolve().parent.parent / "Sources/Assets.xcassets/AppIcon.appiconset"
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
SHADOW_FLOOR = 64  # alpha at/below this is drop shadow, not artwork


def strip_shadow(im: Image.Image) -> Image.Image:
    a = im.getchannel("A").point(
        lambda p: 0 if p <= SHADOW_FLOOR else int((p - SHADOW_FLOOR) * 255 / (255 - SHADOW_FLOOR))
    )
    im = im.copy()
    im.putalpha(a)
    return im


def make_master(src: Path) -> Image.Image:
    im = strip_shadow(Image.open(src).convert("RGBA"))
    bbox = im.getchannel("A").point(lambda p: 255 if p > 128 else 0).getbbox()
    return im.crop(bbox).resize((1024, 1024), Image.LANCZOS)


def main() -> int:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else ICONSET / "icon_512x512@2x.png"
    master = make_master(src)
    for size, scale in SIZES:
        px = size * scale
        out = ICONSET / f"icon_{size}x{size}@{scale}x.png"
        master.resize((px, px), Image.LANCZOS).save(out)
        print(f"wrote {out.name} ({px}x{px})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
