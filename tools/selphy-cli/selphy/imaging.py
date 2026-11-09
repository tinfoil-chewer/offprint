"""Turn photos into print-ready JPEGs and build 1-bit overcoat masks."""
from __future__ import annotations

import io
import math
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps

from .media import Paper

FONT_CANDIDATES = (
    "/usr/share/fonts/google-noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "DejaVuSans-Bold.ttf",
)


def _font(size: int) -> ImageFont.ImageFont:
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default(size)


def load(path: str | Path) -> Image.Image:
    img = Image.open(path)
    img = ImageOps.exif_transpose(img)
    return img.convert("RGB")


@dataclass
class Layout:
    fit: str = "fill"          # fill = crop to cover, fit = whole photo with background
    border_mm: float = 0.0     # white border drawn into the image (0 = borderless)
    background: str = "white"
    rotate: bool = True        # rotate photo to match paper orientation


def render(img: Image.Image, paper: Paper, layout: Layout = Layout()) -> Image.Image:
    """Return an RGB image exactly ``paper.image`` pixels (incl. bleed)."""
    W, H = paper.image
    if layout.rotate and (img.width > img.height) != (W > H) and img.width != img.height:
        img = img.rotate(90, expand=True)

    canvas = Image.new("RGB", (W, H), layout.background)
    bx, by = paper.bleed
    if layout.border_mm > 0:
        b = round(layout.border_mm / 25.4 * 300)
        box = (bx + b, by + b, W - bx - b, H - by - b)
    else:
        box = (0, 0, W, H)            # borderless: cover the bleed too
    bw, bh = box[2] - box[0], box[3] - box[1]

    if layout.fit == "fill":
        placed = ImageOps.fit(img, (bw, bh), Image.Resampling.LANCZOS)
        canvas.paste(placed, box[:2])
    else:
        placed = ImageOps.contain(img, (bw, bh), Image.Resampling.LANCZOS)
        canvas.paste(placed, (box[0] + (bw - placed.width) // 2, box[1] + (bh - placed.height) // 2))
    return canvas


def to_jpeg(img: Image.Image, quality: int = 95) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, subsampling=0, optimize=True)
    return buf.getvalue()


# ---------------------------------------------------------------- overcoat masks
#
# Mask pixels that are WHITE (bit = 1) get the textured overcoat; black stays the
# normal finish.  Masks are drawn in full image coordinates (paper.image) so they
# line up with the photo, then centre-cropped to the printer's mask size.

class Mask:
    def __init__(self, paper: Paper):
        self.paper = paper
        self.img = Image.new("L", paper.image, 0)

    # --- building blocks ---
    def text(self, text: str, size_mm: float = 8, position: str = "bottom-right",
             margin_mm: float = 6, angle: float = 0) -> "Mask":
        px = lambda mm: round(mm / 25.4 * 300)
        font = _font(px(size_mm))
        layer = Image.new("L", self.paper.image, 0)
        d = ImageDraw.Draw(layer)
        l, t, r, b = d.multiline_textbbox((0, 0), text, font=font, align="center")
        tw, th = r - l, b - t
        W, H = self.paper.image
        bx, by = self.paper.bleed
        m = px(margin_mm)
        xs = {"left": bx + m, "center": (W - tw) // 2, "right": W - bx - m - tw}
        ys = {"top": by + m, "center": (H - th) // 2, "bottom": H - by - m - th}
        vert, _, horiz = position.partition("-") if "-" in position else (position, "", position)
        if position == "center":
            vert = horiz = "center"
        d.multiline_text((xs[horiz] - l, ys[vert] - t), text, fill=255, font=font, align="center")
        if angle:
            layer = layer.rotate(angle, center=(xs[horiz] + tw / 2, ys[vert] + th / 2))
        self.img = ImageChops.lighter(self.img, layer)
        return self

    def image(self, path: str | Path, threshold: int = 128, invert: bool = False,
              scale: float = 1.0) -> "Mask":
        """Any picture (logo, signature, drawing) — dark pixels become texture."""
        src = ImageOps.exif_transpose(Image.open(path))
        if src.mode in ("RGBA", "LA") or "transparency" in src.info:
            src = src.convert("RGBA")
            bg = Image.new("RGBA", src.size, "white")
            src = Image.alpha_composite(bg, src)
        gray = src.convert("L")
        W, H = self.paper.image
        target = (round(W * scale), round(H * scale))
        gray = ImageOps.contain(gray, target, Image.Resampling.LANCZOS)
        layer = Image.new("L", (W, H), 255)
        layer.paste(gray, ((W - gray.width) // 2, (H - gray.height) // 2))
        bw = layer.point(lambda v: 255 if v < threshold else 0)
        if invert:
            bw = ImageOps.invert(bw)
        self.img = ImageChops.lighter(self.img, bw)
        return self

    def pattern(self, name: str, spacing_mm: float = 3.0, weight: float = 0.35) -> "Mask":
        """Full-sheet textures: lines, crosshatch, dots, checker, waves, linen."""
        W, H = self.paper.image
        s = max(4, round(spacing_mm / 25.4 * 300))
        lw = max(1, round(s * weight))
        layer = Image.new("L", (W, H), 0)
        d = ImageDraw.Draw(layer)
        if name in ("lines", "crosshatch"):
            for k in range(-H, W + H, s):
                d.line([(k, 0), (k + H, H)], fill=255, width=lw)
                if name == "crosshatch":
                    d.line([(k + H, 0), (k, H)], fill=255, width=lw)
        elif name == "dots":
            r = lw / 2 + 0.5
            for y in range(0, H, s):
                off = s // 2 if (y // s) % 2 else 0
                for x in range(off, W, s):
                    d.ellipse([x - r, y - r, x + r, y + r], fill=255)
        elif name == "checker":
            for y in range(0, H, s):
                for x in range((y // s) % 2 * s, W, 2 * s):
                    d.rectangle([x, y, x + s - 1, y + s - 1], fill=255)
        elif name == "waves":
            amp = s * 0.6
            for y0 in range(-s, H + s, s):
                pts = [(x, y0 + amp * math.sin(x / (s * 1.5))) for x in range(0, W + 4, 4)]
                d.line(pts, fill=255, width=lw)
        elif name == "linen":
            for k in range(0, max(W, H), s):
                d.line([(k, 0), (k, H)], fill=255, width=max(1, lw // 2))
                d.line([(0, k), (W, k)], fill=255, width=max(1, lw // 2))
        else:
            raise ValueError(f"unknown pattern {name!r}")
        self.img = ImageChops.lighter(self.img, layer)
        return self

    def frame(self, width_mm: float = 5) -> "Mask":
        """Texture a band around the visible edge (matte frame, glossy photo)."""
        W, H = self.paper.image
        bx, by = self.paper.bleed
        w = round(width_mm / 25.4 * 300)
        layer = Image.new("L", (W, H), 255)
        ImageDraw.Draw(layer).rectangle([bx + w, by + w, W - bx - w - 1, H - by - w - 1], fill=0)
        self.img = ImageChops.lighter(self.img, layer)
        return self

    def invert(self) -> "Mask":
        self.img = ImageOps.invert(self.img)
        return self

    # --- output ---
    def bitmap(self) -> Image.Image:
        """The mask cropped to printer mask size as a 1-bit image."""
        W, H = self.paper.image
        mw, mh = self.paper.mask
        x, y = (W - mw) // 2, (H - mh) // 2
        return self.img.crop((x, y, x + mw, y + mh)).point(lambda v: 255 if v >= 128 else 0).convert("1")

    def pack(self) -> bytes:
        """Raw MSB-first, row-padded bits — the format the printer expects."""
        data = self.bitmap().tobytes()
        mw, mh = self.paper.mask
        assert len(data) == (mw + 7) // 8 * mh
        return data

    def coverage(self) -> float:
        bm = self.bitmap()
        return sum(1 for v in bm.getdata() if v) / (bm.width * bm.height)


def preview(photo: Image.Image, mask: Mask | None, paper: Paper) -> Image.Image:
    """Approximate on-screen look: textured areas shown with a sheen + hatch."""
    out = photo.copy()
    if mask is not None:
        W, H = paper.image
        mw, mh = paper.mask
        full = Image.new("L", (W, H), 0)
        full.paste(mask.bitmap().convert("L"), ((W - mw) // 2, (H - mh) // 2))
        sheen = Image.new("RGB", (W, H), (255, 255, 255))
        out = Image.composite(Image.blend(out, sheen, 0.35), out, full)
    bx, by = paper.bleed
    d = ImageDraw.Draw(out)
    d.rectangle([bx, by, paper.image[0] - bx - 1, paper.image[1] - by - 1], outline=(255, 0, 0), width=2)
    return out
