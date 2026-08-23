#!/usr/bin/env python3
"""Generate the canonical Semreh app icon and Semreh wordmark assets.

The app icon source is the repository owner's supplied artwork at
Brand/SemrehAppIconSource.png. The pipeline preserves that artwork, creates a
1024×1024 opaque sRGB icon, and deliberately exposes no legacy alternate icons.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "HermesMobile" / "Resources" / "Assets.xcassets"
ICON_SOURCE = ROOT / "Brand" / "SemrehAppIconSource.png"
FONT = "/System/Library/Fonts/SFNSRounded.ttf"


def gradient(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / max(height - 1, 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        draw.line((0, y, width, y), fill=color)
    return image


def rounded_font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT, size=size)


def centered_text_mask(text: str, size: tuple[int, int], font_size: int, y_offset: int = 0) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    font = rounded_font(font_size)
    bounds = draw.textbbox((0, 0), text, font=font, stroke_width=0)
    text_width = bounds[2] - bounds[0]
    text_height = bounds[3] - bounds[1]
    x = (size[0] - text_width) / 2 - bounds[0]
    y = (size[1] - text_height) / 2 - bounds[1] + y_offset
    draw.text((x, y), text, fill=255, font=font)
    return mask


def save_canonical_icon() -> None:
    with Image.open(ICON_SOURCE) as source:
        if source.width != source.height:
            raise ValueError("Semreh app icon source must be square")
        icon = source.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)

    destinations = (
        ASSETS / "AppIcon.appiconset" / "semreh_app_icon.png",
        ASSETS / "SemrehAppIcon.imageset" / "semreh_app_icon.png",
    )
    for destination in destinations:
        destination.parent.mkdir(parents=True, exist_ok=True)
        icon.save(destination, format="PNG", optimize=True)


def save_wordmarks() -> None:
    banner_size = (1286, 202)
    word_mask = centered_text_mask("SEMREH", banner_size, 184, y_offset=-7)
    banner = Image.new("RGBA", banner_size, (0, 0, 0, 0))
    shadow = Image.new("RGBA", banner_size, (0, 0, 0, 0))
    shadow_alpha = ImageChops.offset(word_mask, 8, 11).filter(ImageFilter.GaussianBlur(7))
    shadow.putalpha(shadow_alpha.point(lambda value: round(value * 0.72)))
    banner = Image.alpha_composite(banner, shadow)
    fill = gradient(banner_size, (255, 239, 92), (255, 132, 24)).convert("RGBA")
    fill.putalpha(word_mask)
    banner = Image.alpha_composite(banner, fill)
    outline = Image.new("RGBA", banner_size, (0, 0, 0, 0))
    outline_draw = ImageDraw.Draw(outline)
    font = rounded_font(184)
    bounds = outline_draw.textbbox((0, 0), "SEMREH", font=font, stroke_width=0)
    x = (banner_size[0] - (bounds[2] - bounds[0])) / 2 - bounds[0]
    y = (banner_size[1] - (bounds[3] - bounds[1])) / 2 - bounds[1] - 7
    outline_draw.text((x, y), "SEMREH", font=font, fill=(0, 0, 0, 0), stroke_width=4, stroke_fill=(12, 25, 52, 255))
    banner = Image.alpha_composite(banner, outline)
    banner.save(ASSETS / "SemrehBanner.imageset" / "semreh-banner.png", optimize=True)

    layer_size = (643, 185)
    mask = centered_text_mask("SEMREH", layer_size, 168, y_offset=-5)

    fill_mask = Image.new("RGBA", layer_size, (255, 255, 255, 0))
    fill_mask.putalpha(mask)
    fill_mask.save(ASSETS / "semreh-fill-mask.imageset" / "semreh-fill-mask.png", optimize=True)

    shading = gradient(layer_size, (255, 255, 255), (82, 82, 82)).convert("RGBA")
    shading.putalpha(mask.point(lambda value: round(value * 0.42)))
    shading.save(ASSETS / "semreh-shading-overlay.imageset" / "semreh-shading-overlay.png", optimize=True)

    highlight_alpha = ImageChops.offset(mask, -2, -3).filter(ImageFilter.GaussianBlur(1))
    highlight = Image.new("RGBA", layer_size, (255, 255, 255, 0))
    highlight.putalpha(highlight_alpha.point(lambda value: round(value * 0.34)))
    highlight.save(ASSETS / "semreh-highlight.imageset" / "semreh-highlight.png", optimize=True)

    expanded = mask.filter(ImageFilter.MaxFilter(9))
    outline_alpha = ImageChops.subtract(expanded, mask)
    shadow_alpha = ImageChops.offset(outline_alpha, 3, 5).filter(ImageFilter.GaussianBlur(2))
    outline_shadow = Image.new("RGBA", layer_size, (9, 17, 33, 0))
    outline_shadow.putalpha(shadow_alpha.point(lambda value: round(value * 0.9)))
    outline_shadow.save(ASSETS / "semreh-outline-shadow.imageset" / "semreh-outline-shadow.png", optimize=True)


if __name__ == "__main__":
    save_canonical_icon()
    save_wordmarks()
    print("Generated canonical Semreh app icon and wordmarks.")
