"""Draws the Memopila app icon into App/Memopila/Assets.xcassets/AppIcon.appiconset.

A stacked clipboard on a blue squircle. Rendered at 4x and downsampled for smooth edges.
Usage: python3 scripts/make_app_icon.py
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SCALE = 4
SIZE = 1024 * SCALE
OUT = Path(__file__).resolve().parent.parent / "App/Memopila/Assets.xcassets/AppIcon.appiconset"


def s(value):
    return int(value * SCALE)


def vertical_gradient(size, top, bottom):
    width, height = size
    gradient = Image.new("RGBA", size)
    draw = ImageDraw.Draw(gradient)
    for y in range(height):
        t = y / max(height - 1, 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        draw.line([(0, y), (width, y)], fill=color)
    return gradient


def rounded_mask(box, radius):
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def draw_icon():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tile = (s(100), s(100), s(924), s(924))

    # Soft shadow under the tile, as in the macOS icon grid.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((s(100), s(118), s(924), s(942)), radius=s(185), fill=(0, 0, 40, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(s(18))))

    background = vertical_gradient((SIZE, SIZE), (92, 140, 255), (52, 58, 214))
    canvas.paste(background, (0, 0), rounded_mask(tile, s(185)))

    draw = ImageDraw.Draw(canvas)
    # The card behind: earlier history.
    back = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(back).rounded_rectangle((s(338), s(300), s(762), s(850)), radius=s(48), fill=(255, 255, 255, 90))
    canvas = Image.alpha_composite(canvas, back)
    draw = ImageDraw.Draw(canvas)

    # The clipboard.
    board = (s(292), s(258), s(716), s(808))
    board_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(board_shadow).rounded_rectangle((board[0], board[1] + s(14), board[2], board[3] + s(14)), radius=s(48), fill=(10, 16, 80, 120))
    canvas = Image.alpha_composite(canvas, board_shadow.filter(ImageFilter.GaussianBlur(s(14))))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(board, radius=s(48), fill=(247, 249, 255, 255))

    # Clip.
    draw.rounded_rectangle((s(412), s(212), s(596), s(316)), radius=s(32), fill=(30, 38, 112, 255))
    draw.ellipse((s(482), s(234), s(526), s(278)), fill=(247, 249, 255, 255))

    # Text lines.
    lines = [(s(372), 300, (79, 123, 255)), (s(462), 340, (99, 135, 255)), (s(552), 260, (120, 150, 255)), (s(642), 200, (150, 172, 255))]
    for y, width, color in lines:
        draw.rounded_rectangle((s(352), y, s(352) + s(width), y + s(40)), radius=s(20), fill=color + (255,))

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    master = draw_icon()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(OUT / name)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    (OUT / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (OUT.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
