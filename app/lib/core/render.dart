/// Draws sheets and overcoat designs. The same code paints the on-screen
/// preview (scaled) and the 300 dpi print image, so preview == print.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';

import 'media.dart';
import 'models.dart';

double _px(double mm) => Paper.mmToPx(mm);

/// Cell rectangles (image pixel coordinates) for a sheet layout.
List<Rect> cellRects(PrintJob job) {
  final p = job.paper;
  final full = Rect.fromLTWH(0, 0, p.imageWidth.toDouble(), p.imageHeight.toDouble());
  final paper = Rect.fromLTWH(p.bleedX.toDouble(), p.bleedY.toDouble(), p.paperWidth.toDouble(), p.paperHeight.toDouble());
  final border = _px(job.borderMm);
  final area = paper.deflate(border);
  final gap = _px(job.gapMm);

  // grid in "portrait" terms, transposed for landscape paper
  final (cols, rows) = switch (job.layout) {
    LayoutKind.single => (1, 1),
    LayoutKind.grid2 => (1, 2),
    LayoutKind.grid4 => (2, 2),
    LayoutKind.mini8 => (2, 4),
    LayoutKind.strips => (2, 4),
  };
  final (c, r) = p.landscape ? (rows, cols) : (cols, rows);
  final colGap = job.layout == LayoutKind.strips ? math.max(gap, _px(4)) : gap;
  final cw = (area.width - colGap * (c - 1)) / c;
  final ch = (area.height - gap * (r - 1)) / r;

  final rects = <Rect>[];
  // strips: fill column-major so each strip is a sequence of 4
  for (var i = 0; i < c * r; i++) {
    final (col, row) = job.layout == LayoutKind.strips && !p.landscape ? (i ~/ r, i % r) : (i % c, i ~/ c);
    var rect = Rect.fromLTWH(area.left + col * (cw + colGap), area.top + row * (ch + gap), cw, ch);
    if (border == 0) {
      // bleed outer edges past the paper edge
      rect = Rect.fromLTRB(
        col == 0 ? full.left : rect.left,
        row == 0 ? full.top : rect.top,
        col == c - 1 ? full.right : rect.right,
        row == r - 1 ? full.bottom : rect.bottom,
      );
    }
    rects.add(rect);
  }
  return rects;
}

/// Which photo goes in which cell (strips repeat the same 4 photos twice).
List<PhotoSlot?> cellSlots(PrintJob job, int sheet) {
  if (job.layout == LayoutKind.strips) {
    final four = job.slotsForSheet(sheet);
    return [...four, ...four];
  }
  return job.slotsForSheet(sheet);
}

/// Total quarter turns: auto-rotation to the cell's orientation plus the user's.
int effectiveTurns(PhotoSlot slot, Rect cell) {
  final img = slot.source.image;
  final auto = slot.autoRotate && img.width != img.height && cell.width != cell.height &&
      (img.width > img.height) != (cell.width > cell.height);
  return (slot.quarterTurns + (auto ? 1 : 0)) % 4;
}

/// Destination rect of a photo inside a cell (cover-fit, zoom, pan, rotation).
Rect photoRect(PhotoSlot slot, Rect cell) {
  final rotated = effectiveTurns(slot, cell).isOdd;
  final iw = (rotated ? slot.source.image.height : slot.source.image.width).toDouble();
  final ih = (rotated ? slot.source.image.width : slot.source.image.height).toDouble();
  final scale = math.max(cell.width / iw, cell.height / ih) * slot.zoom;
  final w = iw * scale, h = ih * scale;
  final ox = (w - cell.width) / 2, oy = (h - cell.height) / 2;
  return Rect.fromLTWH(cell.left - ox - slot.pan.dx * ox, cell.top - oy - slot.pan.dy * oy, w, h);
}

void _drawPhoto(Canvas canvas, PhotoSlot slot, Rect cell) {
  final dst = photoRect(slot, cell);
  final image = slot.source.image;
  final paint = Paint()
    ..filterQuality = FilterQuality.high
    ..isAntiAlias = true
    ..colorFilter = slot.adjust.toColorFilter();
  canvas.save();
  canvas.clipRect(cell);
  canvas.translate(dst.center.dx, dst.center.dy);
  final turns = effectiveTurns(slot, cell);
  canvas.rotate(turns * math.pi / 2);
  final rotated = turns.isOdd;
  final w = rotated ? dst.height : dst.width, h = rotated ? dst.width : dst.height;
  canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(center: Offset.zero, width: w, height: h), paint);
  canvas.restore();
}

Offset _spotOffset(TextSpot spot, Size box, Rect area) {
  final a = spot.alignment;
  return Offset(
    area.left + (area.width - box.width) * (a.x + 1) / 2,
    area.top + (area.height - box.height) * (a.y + 1) / 2,
  );
}

void _drawText(Canvas canvas, String text, double sizeMm, TextSpot spot, Rect area, Color color,
    {FontWeight weight = FontWeight.w700, bool shadow = false}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Inter',
        color: color,
        fontSize: _px(sizeMm),
        fontWeight: weight,
        height: 1.1,
        shadows: shadow ? [Shadow(color: const Color(0x99000000), blurRadius: _px(0.6))] : null,
      ),
    ),
    textAlign: switch (spot.alignment.x) { < 0 => TextAlign.left, > 0 => TextAlign.right, _ => TextAlign.center },
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: area.width);
  tp.paint(canvas, _spotOffset(spot, tp.size, area));
}

/// Builds a QR code, picking the lowest version that fits the content.
QrImage? buildQr(String content) {
  try {
    return QrImage(QrCode(payload: QrPayload.fromString(content), errorCorrectLevel: QrErrorCorrectLevel.medium));
  } catch (_) {
    return null; // too long
  }
}

void _drawQr(Canvas canvas, QrSpec q, Rect safe) {
  final qr = buildQr(q.content.trim());
  if (qr == null) return;
  const quiet = 2; // modules of white margin around the code
  final n = qr.moduleCount;
  final total = _px(q.sizeMm);
  final module = (total / (n + 2 * quiet)).floorToDouble().clamp(1.0, double.infinity);
  final side = module * (n + 2 * quiet);
  final at = _spotOffset(q.spot, Size(side, side), safe);
  final origin = Offset(at.dx.roundToDouble(), at.dy.roundToDouble());
  if (q.whiteBackground) {
    canvas.drawRRect(RRect.fromRectAndRadius(origin & Size(side, side), Radius.circular(module)), Paint()..color = const Color(0xFFFFFFFF));
  }
  final dark = Paint()..color = const Color(0xFF000000);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (qr.isDark(y, x)) {
        canvas.drawRect(Rect.fromLTWH(origin.dx + (x + quiet) * module, origin.dy + (y + quiet) * module, module, module), dark);
      }
    }
  }
}

/// Paints sheet [sheet] of [job] in image-pixel coordinates.
void paintSheet(Canvas canvas, PrintJob job, int sheet) {
  final p = job.paper;
  canvas.drawRect(Rect.fromLTWH(0, 0, p.imageWidth.toDouble(), p.imageHeight.toDouble()), Paint()..color = job.background);
  final rects = cellRects(job);
  final slots = cellSlots(job, sheet);
  for (var i = 0; i < rects.length; i++) {
    final s = slots[i];
    if (s != null) {
      _drawPhoto(canvas, s, rects[i]);
    } else {
      canvas.drawRect(rects[i], Paint()..color = const Color(0xFFE0E0E0));
    }
  }
  if (job.qr.active) {
    final safe = Rect.fromLTWH(p.bleedX.toDouble(), p.bleedY.toDouble(), p.paperWidth.toDouble(), p.paperHeight.toDouble())
        .deflate(_px(math.max(4, job.borderMm + 2)));
    _drawQr(canvas, job.qr, safe);
  }
  if (!job.caption.isEmpty) {
    final safe = Rect.fromLTWH(p.bleedX.toDouble(), p.bleedY.toDouble(), p.paperWidth.toDouble(), p.paperHeight.toDouble())
        .deflate(_px(math.max(4, job.borderMm + 2)));
    _drawText(canvas, job.caption.text, job.caption.sizeMm, job.caption.spot, safe, job.caption.color,
        weight: FontWeight.w600, shadow: true);
  }
}

/// Paints the overcoat design: white = textured. Background is transparent so
/// the same call works as a preview overlay; [solid] fills black first.
void paintDesign(Canvas canvas, PrintJob job, {bool solid = false, Color ink = const Color(0xFFFFFFFF)}) {
  final p = job.paper;
  final d = job.design;
  final full = Rect.fromLTWH(0, 0, p.imageWidth.toDouble(), p.imageHeight.toDouble());
  final paper = Rect.fromLTWH(p.bleedX.toDouble(), p.bleedY.toDouble(), p.paperWidth.toDouble(), p.paperHeight.toDouble());
  canvas.saveLayer(full, Paint());
  if (solid) canvas.drawRect(full, Paint()..color = const Color(0xFF000000));
  final paint = Paint()..color = ink;

  if (d.pattern != Pattern.none) {
    final s = math.max(4.0, _px(d.patternSpacingMm));
    final lw = math.max(1.0, s * 0.35);
    final stroke = Paint()
      ..color = ink
      ..strokeWidth = lw
      ..style = PaintingStyle.stroke;
    final w = full.width, h = full.height;
    switch (d.pattern) {
      case Pattern.lines || Pattern.crosshatch:
        for (var k = -h; k < w + h; k += s) {
          canvas.drawLine(Offset(k, 0), Offset(k + h, h), stroke);
          if (d.pattern == Pattern.crosshatch) canvas.drawLine(Offset(k + h, 0), Offset(k, h), stroke);
        }
      case Pattern.dots:
        for (var y = 0.0, row = 0; y < h; y += s, row++) {
          for (var x = row.isOdd ? s / 2 : 0.0; x < w; x += s) {
            canvas.drawCircle(Offset(x, y), lw / 2 + 0.5, paint);
          }
        }
      case Pattern.checker:
        for (var y = 0.0, row = 0; y < h; y += s, row++) {
          for (var x = row.isOdd ? s : 0.0; x < w; x += 2 * s) {
            canvas.drawRect(Rect.fromLTWH(x, y, s, s), paint);
          }
        }
      case Pattern.waves:
        for (var y0 = -s; y0 < h + s; y0 += s) {
          final path = Path()..moveTo(0, y0);
          for (var x = 0.0; x <= w; x += 4) {
            path.lineTo(x, y0 + s * 0.6 * math.sin(x / (s * 1.5)));
          }
          canvas.drawPath(path, stroke);
        }
      case Pattern.linen:
        final thin = Paint()
          ..color = ink
          ..strokeWidth = math.max(1, lw / 2);
        for (var k = 0.0; k < math.max(w, h); k += s) {
          canvas.drawLine(Offset(k, 0), Offset(k, h), thin);
          canvas.drawLine(Offset(0, k), Offset(w, k), thin);
        }
      case Pattern.none:
        break;
    }
  }

  if (d.frameMm > 0) {
    final inner = paper.deflate(_px(d.frameMm));
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(full)
        ..addRect(inner),
      paint,
    );
  }

  final logo = d.logo;
  if (logo != null) {
    final area = paper.deflate(_px(6));
    final scale = math.min(area.width * d.logoScale / logo.width, area.height * d.logoScale / logo.height);
    final size = Size(logo.width * scale, logo.height * scale);
    final at = _spotOffset(d.logoSpot, size, area);
    // dark pixels -> ink (alpha = A - luminance)
    final r = ink.r * 255, g = ink.g * 255, b = ink.b * 255;
    canvas.drawImageRect(
      logo,
      Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      at & size,
      Paint()
        ..filterQuality = FilterQuality.high
        ..colorFilter = ColorFilter.matrix([
          0, 0, 0, 0, r,
          0, 0, 0, 0, g,
          0, 0, 0, 0, b,
          -0.2126 * ink.a, -0.7152 * ink.a, -0.0722 * ink.a, ink.a, 0,
        ]),
    );
  }

  if (d.text.trim().isNotEmpty) {
    _drawText(canvas, d.text, d.textSizeMm, d.textSpot, paper.deflate(_px(6)), ink);
  }

  if (d.invert && !solid) {
    canvas.drawRect(full, Paint()
      ..color = ink
      ..blendMode = BlendMode.xor);
  }
  canvas.restore();
}

Future<ui.Image> _record(int w, int h, void Function(Canvas) draw) async {
  final rec = ui.PictureRecorder();
  draw(Canvas(rec));
  final pic = rec.endRecording();
  final image = await pic.toImage(w, h);
  pic.dispose();
  return image;
}

/// A rendered sheet ready to send.
class RenderedSheet {
  RenderedSheet({required this.jpeg, required this.width, required this.height, this.mask, this.maskCoverage = 0});
  final Uint8List jpeg;
  final int width, height;
  final Uint8List? mask;
  final double maskCoverage;
}

Future<RenderedSheet> renderSheet(PrintJob job, int sheet, {bool portraitForIpp = false}) async {
  final p = job.paper;
  final image = await _record(p.imageWidth, p.imageHeight, (c) => paintSheet(c, job, sheet));
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final w = image.width, h = image.height;
  image.dispose();
  final rotate = portraitForIpp && p.landscape;
  final jpeg = await _encodeInIsolate(rgba, w, h, rotate);

  Uint8List? mask;
  var coverage = 0.0;
  if (job.hasDesign) {
    final m = await _record(p.imageWidth, p.imageHeight, (c) => paintDesign(c, job, solid: true));
    final mrgba = (await m.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    m.dispose();
    final res = await _packInIsolate(mrgba, p.imageWidth, p.imageHeight, p.maskWidth, p.maskHeight, job.design.invert);
    mask = res.$1;
    coverage = res.$2;
  }
  return RenderedSheet(
    jpeg: jpeg,
    width: rotate ? h : w,
    height: rotate ? w : h,
    mask: mask,
    maskCoverage: coverage,
  );
}

// Isolate entry points take only plain data: closures created inside functions
// that hold dart:ui objects would capture them and fail to send.
Future<Uint8List> _encodeInIsolate(Uint8List rgba, int w, int h, bool rotate) =>
    Isolate.run(() => _encodeJpeg(rgba, w, h, rotate));

Future<(Uint8List, double)> _packInIsolate(Uint8List rgba, int w, int h, int mw, int mh, bool invert) =>
    Isolate.run(() => packMask(rgba, w, h, mw, mh, invert: invert));

Future<Uint8List> _thumbInIsolate(Uint8List rgba, int w, int h) => Isolate.run(
    () => img.encodeJpg(img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4), quality: 80));

Uint8List _encodeJpeg(Uint8List rgba, int w, int h, bool rotate) {
  var im = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4);
  if (rotate) im = img.copyRotate(im, angle: 90);
  return img.encodeJpg(im, quality: 95, chroma: img.JpegChroma.yuv444);
}

/// Centre-crops an RGBA design render to the mask size and packs it MSB-first.
(Uint8List, double) packMask(Uint8List rgba, int w, int h, int mw, int mh, {bool invert = false}) {
  final stride = (mw + 7) ~/ 8;
  final out = Uint8List(stride * mh);
  final x0 = (w - mw) ~/ 2, y0 = (h - mh) ~/ 2;
  var set = 0;
  for (var y = 0; y < mh; y++) {
    final row = (y0 + y) * w;
    for (var x = 0; x < mw; x++) {
      if ((rgba[(row + x0 + x) * 4] >= 128) != invert) {
        out[y * stride + (x >> 3)] |= 0x80 >> (x & 7);
        set++;
      }
    }
  }
  return (out, set / (mw * mh));
}

/// Decodes photo bytes, applies EXIF orientation and caps the size.
Future<ui.Image> loadPhoto(Uint8List bytes, {int maxEdge = 3200}) async {
  final (rgba, w, h) = await Isolate.run(() {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw const FormatException('Unsupported image');
    var im = img.bakeOrientation(decoded);
    if (math.max(im.width, im.height) > maxEdge) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxEdge, interpolation: img.Interpolation.cubic)
          : img.copyResize(im, height: maxEdge, interpolation: img.Interpolation.cubic);
    }
    final rgba = im.convert(numChannels: 4, format: img.Format.uint8).getBytes(order: img.ChannelOrder.rgba);
    return (rgba, im.width, im.height);
  });
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final desc = ui.ImageDescriptor.raw(buffer, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await desc.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  desc.dispose();
  buffer.dispose();
  return frame.image;
}

/// Small JPEG thumbnail of a sheet for local history.
Future<Uint8List> thumbnail(PrintJob job, int sheet, {int maxEdge = 360}) async {
  final p = job.paper;
  final s = maxEdge / math.max(p.imageWidth, p.imageHeight);
  final w = (p.imageWidth * s).round(), h = (p.imageHeight * s).round();
  final image = await _record(w, h, (c) {
    c.scale(s);
    paintSheet(c, job, sheet);
  });
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  image.dispose();
  return _thumbInIsolate(rgba, w, h);
}
