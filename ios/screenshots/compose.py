#!/usr/bin/env python3
"""Dress the raw simulator captures as App Store frames.

A bare capture is honest but flat, and the store gallery shows these at
thumbnail size where the app's own 13pt terminal text is unreadable. So each
capture is printed on a plate: the app's `panel` ground, a caption in the app's
own typographic system (SF Mono, micro-caps label, tabular figures), one
edge-to-edge hairline, one tick scale, and two corner registration marks on the
capture. Nothing here invents a colour or a face: every value comes from
DESIGN.md, and no device bezel is drawn, because Apple does not require one and
a drawn bezel is decoration this world has no grammar for.

    ios/screenshots/compose.py

Reads ios/screenshots/raw/<device>/, writes ios/screenshots/<locale>/<slot>/.
"""

from __future__ import annotations

import json
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent

# DESIGN.md chrome tokens. One Dark Pro, verbatim.
GROUND = (0x28, 0x2C, 0x34)
PANEL = (0x21, 0x25, 0x2B)
RULE = (0x3E, 0x44, 0x51)
INK_MUTED = (0x94, 0x9C, 0xAB)
INK_BRIGHT = (0xD7, 0xDA, 0xE0)
ACCENT = (0x61, 0xAF, 0xEF)

SF_MONO_MEDIUM = (
    "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/"
    "SF-Mono-Medium.otf"
)
SF_MONO_REGULAR = (
    "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/"
    "SF-Mono-Regular.otf"
)
# SF Mono carries no Hangul, and there is no monospaced Korean face on the
# system, so the Korean caption sets in Apple's own Korean UI face. The label
# line stays Latin in both locales: it is instrument silkscreen, the same
# register as the app's own SESS/GEOM/AGE columns.
KOREAN = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
KOREAN_INDEX = 2  # Medium

SLOTS = {
    "iphone": ("APP_IPHONE_67", 1290, 2796),
    "ipad": ("APP_IPAD_PRO_3GEN_129", 2048, 2732),
}

LOCALES = ("en-US", "ko")


def font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, size, index=index)


def wrap(draw: ImageDraw.ImageDraw, text: str, face, max_width: int) -> list[str]:
    """Greedy wrap. Korean has no spaces at every break point, so a word that
    does not fit on its own is broken by character rather than left to run off
    the plate."""
    lines: list[str] = []
    for word in text.split(" "):
        if not lines:
            lines = [word]
            continue
        trial = lines[-1] + " " + word
        if draw.textlength(trial, font=face) <= max_width:
            lines[-1] = trial
        else:
            lines.append(word)
    out: list[str] = []
    for line in lines:
        while draw.textlength(line, font=face) > max_width and len(line) > 1:
            cut = len(line)
            while cut > 1 and draw.textlength(line[:cut], font=face) > max_width:
                cut -= 1
            out.append(line[:cut])
            line = line[cut:]
        out.append(line)
    return out


def tracked(draw: ImageDraw.ImageDraw, xy, text: str, face, fill, tracking: float):
    """Letter-spaced text. The micro-caps label is tracked +0.8pt at 10pt in the
    app, which is what makes it read as annotation rather than as a word."""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=face, fill=fill)
        x += draw.textlength(ch, font=face) + tracking


def compose(capture: Image.Image, label: str, caption: str, locale: str,
            width: int, height: int) -> Image.Image:
    gutter = round(width * 0.075)
    canvas = Image.new("RGB", (width, height), PANEL)
    draw = ImageDraw.Draw(canvas)

    label_size = round(width * 0.023)
    caption_size = round(width * 0.046)
    if locale == "ko":
        caption_face = font(KOREAN, caption_size, KOREAN_INDEX)
        line_step = round(caption_size * 1.36)
    else:
        caption_face = font(SF_MONO_MEDIUM, caption_size)
        line_step = round(caption_size * 1.30)
    label_face = font(SF_MONO_MEDIUM, label_size)

    text_width = width - 2 * gutter
    lines = wrap(draw, caption, caption_face, text_width)

    label_y = round(height * 0.042)
    caption_y = label_y + round(label_size * 2.6)
    band_bottom = caption_y + line_step * len(lines) + round(height * 0.022)

    tracked(draw, (gutter, label_y), label, label_face, INK_MUTED,
            tracking=label_size * 0.08)
    for i, line in enumerate(lines):
        draw.text((gutter, caption_y + i * line_step), line,
                  font=caption_face, fill=INK_BRIGHT)

    # One hairline, edge to edge, never inset to fake a card. 0.5pt at 3x.
    hair = max(2, round(width / 645))
    draw.rectangle([0, band_bottom, width, band_bottom + hair - 1], fill=RULE)

    # The one tick scale on the plate: a 4pt tick every 16pt, scaled.
    tick_len = round(width * 0.010)
    tick_gap = round(width * 0.031)
    x = gutter
    while x < gutter + text_width * 0.42:
        draw.rectangle([x, band_bottom + hair, x + hair - 1,
                        band_bottom + hair + tick_len], fill=RULE)
        x += tick_gap

    # The capture, printed as a plate under the band.
    top = band_bottom + round(height * 0.030)
    bottom_margin = round(height * 0.020)
    avail_h = height - top - bottom_margin
    avail_w = width - 2 * round(width * 0.055)
    scale = min(avail_w / capture.width, avail_h / capture.height)
    shot = capture.resize(
        (round(capture.width * scale), round(capture.height * scale)),
        Image.LANCZOS,
    )
    sx = (width - shot.width) // 2
    canvas.paste(shot, (sx, top))

    # A hairline round the plate. The app's ground and the panel this is
    # printed on are two neighbouring One Dark Pro neutrals, so without a rule
    # the capture has no edge; this is the same 0.5pt hairline the app draws its
    # own regions with, square-cornered, no fill and no shadow.
    draw.rectangle([sx - hair, top - hair, sx + shot.width + hair - 1,
                    top + shot.height + hair - 1], outline=RULE, width=hair)

    # Two corner registration marks, opposite corners, never four: four reads as
    # a frame (DESIGN.md).
    arm = round(width * 0.019)
    stroke = hair
    off = round(width * 0.010)
    x0, y0 = sx - off, top - off
    x1, y1 = sx + shot.width + off, top + shot.height + off
    draw.rectangle([x0, y0, x0 + arm, y0 + stroke - 1], fill=RULE)
    draw.rectangle([x0, y0, x0 + stroke - 1, y0 + arm], fill=RULE)
    draw.rectangle([x1 - arm, y1 - stroke + 1, x1, y1], fill=RULE)
    draw.rectangle([x1 - stroke + 1, y1 - arm, x1, y1], fill=RULE)

    return canvas


def main() -> int:
    captions = json.loads((ROOT / "captions.json").read_text(encoding="utf-8"))
    for device, frames in captions.items():
        slot, width, height = SLOTS[device]
        for locale in LOCALES:
            out_dir = ROOT / locale / slot
            out_dir.mkdir(parents=True, exist_ok=True)
            for frame in frames:
                src = ROOT / "raw" / device / frame["file"]
                if not src.exists():
                    print(f"missing {src}", file=sys.stderr)
                    return 1
                capture = Image.open(src).convert("RGB")
                image = compose(capture, frame["label"], frame[locale], locale,
                                width, height)
                dest = out_dir / frame["file"]
                image.save(dest)
                print(f"{dest.relative_to(ROOT)}  {image.width}x{image.height}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
