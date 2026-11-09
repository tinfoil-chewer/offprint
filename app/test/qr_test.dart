import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:offprint/core/direct_wifi.dart';
import 'package:offprint/core/models.dart';
import 'package:offprint/core/render.dart';
import 'package:zxing2/qrcode.dart';

String decodeQr(img.Image image) {
  final source = RGBLuminanceSource(image.width, image.height,
      image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List());
  return QRCodeReader().decode(BinaryBitmap(GlobalHistogramBinarizer(source))).text;
}

void main() {
  group('printer pairing QR', () {
    test('parses a CP1500 code', () {
      final n = parsePrinterQr(r'SPLQR:2.0$CP1500-AB12CD-Q$2$k3yp4ssw0rd')!;
      expect(n.ssid, 'CP1500-AB12CD-Q');
      expect(n.password, 'k3yp4ssw0rd');
      expect(n.wpa3, isFalse);
    });
    test('security "3" means WPA3', () {
      expect(parsePrinterQr(r'SPLQR:2.0$CP1500-AB12CD-Q$3$abcdefgh')!.wpa3, isTrue);
    });
    test('rejects other codes', () {
      expect(parsePrinterQr('https://example.com'), isNull);
      expect(parsePrinterQr(r'SPLQR:2.0$CP1500-AB12CD-Q$2'), isNull); // missing password
      expect(parsePrinterQr(r'SPLQR:2.0$CP1500-AB12CD-Q$2$short'), isNull);
    });
    test('SSID from printer ID', () {
      expect(PrinterNetwork.fromId('ab12cd', 'x').ssid, 'CP1500-AB12CD-Q');
    });
  });

  testWidgets('printed QR code decodes back to its content', (tester) async {
    await tester.runAsync(() async {
      final photo = await loadPhoto(File('test/fixtures/testchart.jpg').readAsBytesSync());
      const url = 'https://example.com/our-wedding-album?code=2026';
      final job = PrintJob(photos: [PhotoSlot(PhotoSource('t', photo))])
        ..qr.enabled = true
        ..qr.content = url
        ..qr.sizeMm = 18;
      final r = await renderSheet(job, 0);
      final printed = img.decodeJpg(r.jpeg)!;
      // decode from a crop of the bottom-right corner, roughly as a phone would see it
      final crop = img.copyCrop(printed, x: printed.width - 400, y: printed.height - 400, width: 400, height: 400);
      expect(decodeQr(crop), url);
    });
  });
}
