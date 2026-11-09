/// Paper geometry for SELPHY CP-series printers at 300 dpi.
///
/// From SELPHY Photo Layout's `assets/paper.json` and the overcoat mask sizes
/// in `CPNPMakedata.OvercoatInfo`. See docs/PROTOCOL.md.
library;

class Paper {
  const Paper({
    required this.key,
    required this.name,
    required this.ippMedia,
    required this.ippWidth,
    required this.ippHeight,
    required this.cpnpSize,
    required this.imageWidth,
    required this.imageHeight,
    required this.paperWidth,
    required this.paperHeight,
    required this.maskWidth,
    required this.maskHeight,
  });

  final String key;
  final String name;
  final String ippMedia;

  /// IPP media-size in 1/100 mm (portrait).
  final int ippWidth, ippHeight;

  /// CPNP StartSpool print-size code.
  final int cpnpSize;

  /// Full print image including bleed (px).
  final int imageWidth, imageHeight;

  /// Visible paper area (px), centred in the image.
  final int paperWidth, paperHeight;

  /// Overcoat mask size (px), centred in the image.
  final int maskWidth, maskHeight;

  bool get landscape => imageWidth > imageHeight;
  int get bleedX => (imageWidth - paperWidth) ~/ 2;
  int get bleedY => (imageHeight - paperHeight) ~/ 2;
  int get maskStride => (maskWidth + 7) ~/ 8;
  int get maskBytes => maskStride * maskHeight;

  static double mmToPx(double mm) => mm / 25.4 * 300;

  static const postcard = Paper(
    key: 'postcard', name: 'Postcard 100×148 mm', ippMedia: 'jpn_hagaki_100x148mm',
    ippWidth: 10000, ippHeight: 14800, cpnpSize: 4,
    imageWidth: 1248, imageHeight: 1872, paperWidth: 1184, paperHeight: 1752,
    maskWidth: 1232, maskHeight: 1800,
  );
  static const lSize = Paper(
    key: 'l', name: 'L 89×119 mm', ippMedia: 'om_dsc-photo_89x119mm',
    ippWidth: 8900, ippHeight: 11900, cpnpSize: 3,
    imageWidth: 1152, imageHeight: 1472, paperWidth: 1054, paperHeight: 1409,
    maskWidth: 1100, maskHeight: 1456,
  );
  static const card = Paper(
    key: 'card', name: 'Card 54×86 mm', ippMedia: 'om_card_54x86mm',
    ippWidth: 5400, ippHeight: 8600, cpnpSize: 2,
    imageWidth: 1088, imageHeight: 668, paperWidth: 1018, paperHeight: 640,
    maskWidth: 1040, maskHeight: 668,
  );

  static const all = [postcard, lSize, card];
  static Paper byKey(String key) => all.firstWhere((p) => p.key == key, orElse: () => postcard);
}

/// Surface finish. A custom overcoat design replaces the finish (verified on a
/// CP1500: design areas textured, everything else glossy).
enum Finish {
  gloss(2, 'Gloss'),
  semiGloss(4, 'Semi-gloss'),
  satin(5, 'Satin');

  const Finish(this.code, this.label);
  final int code;
  final String label;
}
