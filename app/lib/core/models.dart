import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'media.dart';

/// How photos are arranged on a sheet.
enum LayoutKind {
  single('Single', 'One photo per sheet', 1),
  grid2('2-up', 'Two photos', 2),
  grid4('4-up', 'Four photos', 4),
  mini8('Mini 8', 'Eight wallet-size photos', 8),
  strips('Photo strips', 'Two booth strips of 4, cut down the middle', 4);

  const LayoutKind(this.label, this.description, this.slotsPerSheet);
  final String label, description;
  final int slotsPerSheet;
}

/// Surface: a plain finish, or a custom overcoat design (which replaces the finish).
enum Surface {
  gloss('Gloss'),
  semiGloss('Semi-gloss'),
  satin('Satin'),
  design('Custom design');

  const Surface(this.label);
  final String label;

  Finish get finish => switch (this) {
        Surface.gloss => Finish.gloss,
        Surface.semiGloss => Finish.semiGloss,
        // Design areas print textured; Satin is what the verified test used.
        Surface.satin || Surface.design => Finish.satin,
      };
}

enum TextSpot {
  topLeft, topCenter, topRight, centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight;

  Alignment get alignment => Alignment((index % 3) - 1.0, (index ~/ 3) - 1.0);
}

enum Pattern { none, lines, crosshatch, dots, checker, waves, linen }

/// A decoded, orientation-corrected photo.
class PhotoSource {
  PhotoSource(this.path, this.image);
  final String path;
  final ui.Image image;
  String get name => path.split(RegExp(r'[\\/]')).last;
}

/// Per-photo adjustments.
class Adjust {
  double brightness = 0; // -1..1
  double contrast = 0; // -1..1
  double saturation = 0; // -1..1
  double warmth = 0; // -1..1
  bool blackAndWhite = false;

  bool get isIdentity => brightness == 0 && contrast == 0 && saturation == 0 && warmth == 0 && !blackAndWhite;

  ColorFilter? toColorFilter() {
    if (isIdentity) return null;
    final s = blackAndWhite ? 0.0 : 1 + saturation;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    final c = 1 + contrast;
    final t = (0.5 * (1 - c) + brightness * 0.5) * 255;
    final warm = warmth * 20;
    final m = <double>[
      c * (sr + s), c * sg, c * sb, 0, t + warm,
      c * sr, c * (sg + s), c * sb, 0, t,
      c * sr, c * sg, c * (sb + s), 0, t - warm,
      0, 0, 0, 1, 0,
    ];
    return ColorFilter.matrix(m);
  }
}

/// One photo placed in a layout cell.
class PhotoSlot {
  PhotoSlot(this.source);
  PhotoSource source;
  double zoom = 1; // >= 1
  Offset pan = Offset.zero; // -1..1 within the overflow
  int quarterTurns = 0;
  bool autoRotate = true; // turn to match the cell's orientation
  final Adjust adjust = Adjust();

  void reset() {
    zoom = 1;
    pan = Offset.zero;
    quarterTurns = 0;
  }
}

/// Custom overcoat design. White = textured in the clear coat.
class DesignSpec {
  String text = '';
  double textSizeMm = 8;
  TextSpot textSpot = TextSpot.bottomRight;
  Pattern pattern = Pattern.none;
  double patternSpacingMm = 3;
  double frameMm = 0;
  ui.Image? logo;
  String? logoPath;
  double logoScale = 0.4;
  TextSpot logoSpot = TextSpot.center;
  bool invert = false;

  bool get isEmpty => text.trim().isEmpty && pattern == Pattern.none && frameMm <= 0 && logo == null && !invert;
}

/// Caption printed in ink (date, place, name…).
class Caption {
  String text = '';
  double sizeMm = 4;
  TextSpot spot = TextSpot.bottomRight;
  Color color = const Color(0xFFFFFFFF);
  bool get isEmpty => text.trim().isEmpty;
}

/// A QR code printed in ink (link, text, Wi-Fi details…).
class QrSpec {
  bool enabled = false;
  String content = '';
  double sizeMm = 18; // ~0.5 mm modules for a short URL: easy to scan
  TextSpot spot = TextSpot.bottomRight;
  bool whiteBackground = true; // quiet-zone tile so it scans on any photo

  bool get active => enabled && content.trim().isNotEmpty;
}

/// Everything needed to produce one or more sheets.
class PrintJob {
  PrintJob({required this.photos, this.layout = LayoutKind.single, this.paper = Paper.postcard});

  final List<PhotoSlot> photos;
  LayoutKind layout;
  Paper paper;
  double borderMm = 0;
  double gapMm = 2;
  Color background = const Color(0xFFFFFFFF);
  Surface surface = Surface.gloss;
  final DesignSpec design = DesignSpec();
  final Caption caption = Caption();
  final QrSpec qr = QrSpec();
  bool autoCorrect = false;
  int copies = 1;

  int get sheetCount => math.max(1, (photos.length / layout.slotsPerSheet).ceil());

  List<PhotoSlot?> slotsForSheet(int sheet) {
    final n = layout.slotsPerSheet;
    return [for (var i = 0; i < n; i++) (sheet * n + i < photos.length) ? photos[sheet * n + i] : null];
  }

  bool get hasDesign => surface == Surface.design && !design.isEmpty;
}
