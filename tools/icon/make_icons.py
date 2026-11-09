#!/usr/bin/env python3
"""Draws the Offprint icon and writes it for Android, Windows and Linux.

Usage: python3 tools/icon/make_icons.py   (from the repository root; needs Pillow)
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
S = 4096  # supersampled canvas


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def draw() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # background tile: indigo vertical gradient, rounded
    grad = Image.new("RGBA", (S, S))
    top, bottom = (58, 58, 60), (18, 18, 20)
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S) + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
    img.paste(grad, (0, 0), mask)

    # the print: white card, slightly rotated, with a soft shadow
    card = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cw, ch = int(S * 0.50), int(S * 0.62)
    x0, y0 = (S - cw) // 2, (S - ch) // 2 + int(S * 0.01)
    cd = ImageDraw.Draw(card)
    cd.rounded_rectangle([x0, y0, x0 + cw, y0 + ch], radius=int(S * 0.025), fill=(255, 255, 255, 255))
    # photo area
    m = int(cw * 0.08)
    px0, py0, px1, py1 = x0 + m, y0 + m, x0 + cw - m, y0 + int(ch * 0.74)
    sky = Image.new("RGBA", (px1 - px0, py1 - py0))
    sd = ImageDraw.Draw(sky)
    for y in range(py1 - py0):
        sd.line([(0, y), (px1 - px0, y)], fill=lerp((236, 236, 238), (176, 176, 180), y / (py1 - py0)) + (255,))
    w, h = sky.size
    sd.ellipse([w * 0.58, h * 0.16, w * 0.80, h * 0.38], fill=(255, 255, 255, 255))
    sd.polygon([(0, h), (w * 0.30, h * 0.42), (w * 0.55, h * 0.78), (w * 0.72, h * 0.56), (w, h * 0.92), (w, h)], fill=(88, 88, 92, 255))
    sd.polygon([(0, h), (w * 0.18, h * 0.70), (w * 0.42, h), ], fill=(44, 44, 48, 255))
    card.paste(sky, (px0, py0))
    # perforation dots near the bottom, a nod to postcard tabs
    dots_y = y0 + int(ch * 0.86)
    r = int(S * 0.006)
    for i in range(14):
        cx = x0 + m + i * (cw - 2 * m) / 13
        cd.ellipse([cx - r, dots_y - r, cx + r, dots_y + r], fill=(200, 200, 204, 255))

    card = card.rotate(-8, resample=Image.BICUBIC, center=(S / 2, S / 2))
    shadow = card.split()[3].point(lambda a: int(a * 0.35)).filter(ImageFilter.GaussianBlur(S * 0.02))
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh.putalpha(shadow)
    img.alpha_composite(sh, (int(S * 0.01), int(S * 0.025)))
    img.alpha_composite(card)
    return img


def main() -> None:
    icon = draw()
    out = lambda size: icon.resize((size, size), Image.LANCZOS)
    master = ROOT / "app/assets/icon/offprint.png"
    master.parent.mkdir(parents=True, exist_ok=True)
    out(1024).save(master)
    (ROOT / "packaging/linux").mkdir(parents=True, exist_ok=True)
    out(256).save(ROOT / "packaging/linux/io.github.tinfoilchewer.offprint.png")
    for folder, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        out(size).save(ROOT / f"app/android/app/src/main/res/mipmap-{folder}/ic_launcher.png")
    out(256).save(ROOT / "app/windows/runner/resources/app_icon.ico",
                  sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons written")


if __name__ == "__main__":
    main()
