import 'dart:io';

import 'package:offprint/core/media.dart';
import 'package:offprint/core/models.dart';
import 'package:offprint/core/render.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('renders print image and mask at printer geometry', (tester) async {
    final out = Directory(Platform.environment['RENDER_OUT'] ?? Directory.systemTemp.path);
    await tester.runAsync(() async {
      final photo = await loadPhoto(File('test/fixtures/testchart.jpg').readAsBytesSync());
      expect((photo.width, photo.height), (1800, 1200));
      for (final layout in [LayoutKind.single, LayoutKind.strips]) {
        final job = PrintJob(photos: [PhotoSlot(PhotoSource('t', photo))], layout: layout)
          ..surface = Surface.design
          ..design.frameMm = 4
          ..design.pattern = Pattern.none;
        job.design.text = 'X';
        final r = await renderSheet(job, 0);
        expect((r.width, r.height), (1248, 1872));
        expect(r.mask!.length, Paper.postcard.maskBytes);
        File('${out.path}/dart_${layout.name}.jpg').writeAsBytesSync(r.jpeg);
        // unpack mask to PNG for inspection
        final m = img.Image(width: 1232, height: 1800, numChannels: 1);
        for (var y = 0; y < 1800; y++) {
          for (var x = 0; x < 1232; x++) {
            if (r.mask![y * 154 + (x >> 3)] & (0x80 >> (x & 7)) != 0) m.setPixelRgb(x, y, 255, 255, 255);
          }
        }
        File('${out.path}/dart_${layout.name}_mask.png').writeAsBytesSync(img.encodePng(m));
        // ignore: avoid_print
        print('${layout.name}: jpeg ${r.jpeg.length} B, mask coverage ${(r.maskCoverage * 100).toStringAsFixed(1)}%');
      }
    });
  });
}
