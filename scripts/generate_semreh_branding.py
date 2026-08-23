#!/usr/bin/env python3
"""Generate Semreh's canonical wing-only app icon and logo asset variants.

The supplied transparent logo files are the source of truth:
- Brand/semreh-wing-light.png: navy mark for light surfaces
- Brand/semreh-wing-dark.png: white mark for dark surfaces
- Brand/semreh-wordmark-light.png / -dark.png: matching wordmarks

The app icon intentionally uses the wing only, on an opaque navy field. The
in-app wing and wordmark images are registered as luminosity variants in the
asset catalog so SwiftUI switches them with the system appearance.
"""

from __future__ import annotations

from pathlib import Path
from shutil import copy2

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "Brand"
ASSETS = ROOT / "HermesMobile" / "Resources" / "Assets.xcassets"
WING_DARK = BRAND / "semreh-wing-dark.png"


def save_canonical_icon() -> None:
    size = 1024
    top = (3, 35, 87)
    bottom = (2, 20, 55)
    background = Image.new("RGB", (size, size), top)
    draw = ImageDraw.Draw(background)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        draw.line((0, y, size, y), fill=color)

    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((520, 150, 1000, 630), fill=(18, 199, 181, 42))
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    icon = Image.alpha_composite(background.convert("RGBA"), glow)

    with Image.open(WING_DARK).convert("RGBA") as wing:
        width = 850
        height = round(wing.height * width / wing.width)
        wing = wing.resize((width, height), Image.Resampling.LANCZOS)
        icon.alpha_composite(wing, ((size - width) // 2, 280))

    icon = icon.convert("RGB")
    for destination in (
        ASSETS / "AppIcon.appiconset/semreh_app_icon.png",
        ASSETS / "SemrehAppIcon.imageset/semreh_app_icon.png",
        BRAND / "SemrehAppIconSource.png",
    ):
        destination.parent.mkdir(parents=True, exist_ok=True)
        icon.save(destination, format="PNG", optimize=True)


def copy_logo_sources() -> None:
    destinations = {
        "semreh-wing-light.png": ASSETS / "SemrehWing.imageset/semreh-wing-light.png",
        "semreh-wing-dark.png": ASSETS / "SemrehWing.imageset/semreh-wing-dark.png",
        "semreh-wordmark-light.png": ASSETS / "SemrehWordmark.imageset/semreh-wordmark-light.png",
        "semreh-wordmark-dark.png": ASSETS / "SemrehWordmark.imageset/semreh-wordmark-dark.png",
    }
    for source_name, destination in destinations.items():
        destination.parent.mkdir(parents=True, exist_ok=True)
        copy2(BRAND / source_name, destination)


if __name__ == "__main__":
    copy_logo_sources()
    save_canonical_icon()
    print("Generated Semreh wing-only icon and copied luminosity-aware logo assets.")
