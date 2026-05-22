#!/usr/bin/env python3
"""
Generate the Cadence app icon at 1024x1024.

Concept: a stopwatch sweep. A bold amber arc traces ~270° clockwise from the
upper-left, fading in at the start and brightening as it goes. A bright cream
pip marks the "now" moment at the leading edge.

Rendered at 4× resolution then downsampled with LANCZOS so the gradient is
smooth and the edges anti-alias cleanly. The arc itself is painted as a series
of overlapping antialiased circles ("brush strokes") so there are no slice
seams or banding.

Output: App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
from __future__ import annotations

import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

OUT_SIZE = 1024
SS = 4  # supersample factor
SIZE = OUT_SIZE * SS

OUT = Path(__file__).resolve().parent.parent / "App" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"

# Palette — deep ink navy + warm amber gradient + cream highlight.
INK_DEEP   = (10, 18, 36)
INK_LIGHT  = (28, 44, 80)
AMBER_DIM  = (190, 110, 40)
AMBER      = (255, 173, 64)
AMBER_HOT  = (255, 120, 60)
CREAM      = (255, 240, 210)


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_background(size: int) -> Image.Image:
    """Dark navy with a soft radial vignette toward the corners."""
    bg = Image.new("RGB", (size, size), INK_DEEP)
    px = bg.load()
    cx, cy = size / 2, size / 2
    max_r = math.hypot(cx, cy)
    for y in range(size):
        for x in range(size):
            r = math.hypot(x - cx, y - cy) / max_r
            # Brighter at center, falls off to deep at corners.
            t = max(0.0, 1.0 - r * 0.95)
            px[x, y] = lerp(INK_DEEP, INK_LIGHT, t)
    return bg


def paint_arc(
    img: Image.Image,
    cx: float, cy: float, radius: float, thickness: float,
    start_deg: float, end_deg: float,
    color_a, color_b,
    alpha_start: int = 30, alpha_end: int = 255,
    step_deg: float = 0.25,
):
    """Paint an arc by stamping antialiased circles along its path.
    The brush color blends color_a → color_b and the alpha ramps from
    alpha_start → alpha_end across the sweep. Produces a smooth gradient
    arc with no seams."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    sweep = end_deg - start_deg
    if sweep <= 0:
        return
    n = int(sweep / step_deg) + 1
    half_t = thickness / 2.0
    for i in range(n + 1):
        f = i / n
        a = start_deg + sweep * f
        rad = math.radians(a)
        x = cx + radius * math.cos(rad)
        y = cy + radius * math.sin(rad)
        c = lerp(color_a, color_b, f)
        alpha = int(alpha_start + (alpha_end - alpha_start) * f)
        draw.ellipse(
            (x - half_t, y - half_t, x + half_t, y + half_t),
            fill=(c[0], c[1], c[2], alpha),
        )
    img.alpha_composite(overlay)


def paint_glow(img: Image.Image, x: float, y: float, r: float, color, layers: int = 18):
    """Paint a soft radial glow around (x, y)."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for i in range(layers, 0, -1):
        t = i / layers
        rr = r + r * 1.5 * t
        a = int(70 * (1 - t) ** 1.8)
        d.ellipse(
            (x - rr, y - rr, x + rr, y + rr),
            fill=(color[0], color[1], color[2], a),
        )
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=r * 0.35))
    img.alpha_composite(overlay)


def make_icon() -> Image.Image:
    icon = make_background(SIZE).convert("RGBA")

    cx, cy = SIZE / 2, SIZE / 2

    # Outer arc — bold sweep from upper-left (~210°) around clockwise to lower-right (~470° == 110°).
    # That's a ~260° arc that doesn't quite close, leaving a clean opening at top.
    outer_r = SIZE * 0.34
    outer_t = SIZE * 0.085
    paint_arc(
        icon,
        cx=cx, cy=cy, radius=outer_r, thickness=outer_t,
        start_deg=210, end_deg=470,
        color_a=AMBER_DIM, color_b=AMBER_HOT,
        alpha_start=15, alpha_end=255,
    )

    # Inner ghost arc — much thinner, mirrors the outer slightly inset.
    # Adds depth without competing with the main sweep.
    inner_r = SIZE * 0.22
    inner_t = SIZE * 0.022
    paint_arc(
        icon,
        cx=cx, cy=cy, radius=inner_r, thickness=inner_t,
        start_deg=230, end_deg=450,
        color_a=AMBER_DIM, color_b=AMBER,
        alpha_start=20, alpha_end=140,
    )

    # Tip pip — bright cream dot at the leading edge of the outer arc.
    tip_rad = math.radians(470 - 360)  # 110° (lower-right area)
    tip_x = cx + outer_r * math.cos(tip_rad)
    tip_y = cy + outer_r * math.sin(tip_rad)
    pip_r = SIZE * 0.055
    # Hot glow underlay
    paint_glow(icon, tip_x, tip_y, pip_r, AMBER_HOT, layers=12)
    # Crisp cream pip
    sharp = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    ImageDraw.Draw(sharp).ellipse(
        (tip_x - pip_r, tip_y - pip_r, tip_x + pip_r, tip_y + pip_r),
        fill=(CREAM[0], CREAM[1], CREAM[2], 255),
    )
    # Inner highlight
    hl_r = pip_r * 0.45
    hl_x = tip_x - pip_r * 0.25
    hl_y = tip_y - pip_r * 0.30
    ImageDraw.Draw(sharp).ellipse(
        (hl_x - hl_r, hl_y - hl_r, hl_x + hl_r, hl_y + hl_r),
        fill=(255, 255, 255, 220),
    )
    icon.alpha_composite(sharp)

    # Center anchor — tiny cream dot at the pivot, like a clock's spindle.
    anchor_r = SIZE * 0.012
    anchor = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    ImageDraw.Draw(anchor).ellipse(
        (cx - anchor_r * 3, cy - anchor_r * 3, cx + anchor_r * 3, cy + anchor_r * 3),
        fill=(CREAM[0], CREAM[1], CREAM[2], 60),
    )
    ImageDraw.Draw(anchor).ellipse(
        (cx - anchor_r, cy - anchor_r, cx + anchor_r, cy + anchor_r),
        fill=(CREAM[0], CREAM[1], CREAM[2], 240),
    )
    icon.alpha_composite(anchor)

    # Final composite + downsample
    return icon.convert("RGB").resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon = make_icon()
    icon.save(OUT, format="PNG", optimize=True)
    print(f"Wrote {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
