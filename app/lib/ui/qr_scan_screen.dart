import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../core/direct_wifi.dart';

/// Scans the pairing QR code shown on the SELPHY's screen. Decoding happens
/// on the phone (ZXing); nothing is sent anywhere.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  String? _hint;
  bool _done = false;

  void _onScan(Code code) {
    if (_done || !code.isValid || code.text == null) return;
    final net = parsePrinterQr(code.text!);
    if (net == null) {
      setState(() => _hint = "That isn't a SELPHY connection code.");
      return;
    }
    _done = true;
    Navigator.of(context).pop(net);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan printer QR code')),
      body: Column(children: [
        Expanded(
          child: ReaderWidget(
            codeFormat: Format.qrCode,
            tryHarder: true,
            showGallery: false,
            showToggleCamera: false,
            onScan: _onScan,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Text(
              'On the SELPHY, open the smartphone connection screen so it shows a QR code, then point the camera at it.',
              textAlign: TextAlign.center,
              style: text.bodyMedium,
            ),
            if (_hint != null) ...[
              const SizedBox(height: 8),
              Text(_hint!, style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
            ],
          ]),
        ),
      ]),
    );
  }
}
