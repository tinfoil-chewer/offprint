/// Direct connection to the SELPHY's own Wi-Fi network (no router).
///
/// The printer's screen shows a QR code: `SPLQR:<version>$<ssid>$<security>$<password>`
/// (from SELPHY Photo Layout's CPUtil / Gen2CPUtil). In this mode the printer
/// is always at 192.168.0.1.
library;

import 'dart:io';

import 'package:flutter/services.dart';

const directPrinterAddress = '192.168.0.1';
const _prefix = 'SPLQR:';

class PrinterNetwork {
  const PrinterNetwork({required this.ssid, required this.password, this.wpa3 = false});
  final String ssid;
  final String password;
  final bool wpa3;

  /// SSID from the 6-character printer ID shown on its screen, e.g. CP1500-ABC123-Q.
  factory PrinterNetwork.fromId(String id, String password, {String model = 'CP1500'}) =>
      PrinterNetwork(ssid: '$model-${id.trim().toUpperCase()}-Q', password: password.trim());

  @override
  String toString() => '$ssid (${wpa3 ? 'WPA3' : 'WPA2'})';
}

/// Parses the printer's pairing QR code. Returns null if it is not one.
PrinterNetwork? parsePrinterQr(String text) {
  final t = text.trim();
  if (!t.startsWith(_prefix) || t.length > 64) return null;
  final parts = t.substring(_prefix.length).split(r'$').where((p) => p.isNotEmpty).toList();
  if (parts.length != 4) return null; // version, ssid, security, password
  final [_, ssid, security, password] = parts;
  if (!ssid.startsWith('CP') || ssid.length > 32) return null;
  if (password.length < 8 || password.length > 63) return null;
  return PrinterNetwork(ssid: ssid, password: password, wpa3: security == '3');
}

/// True where the app can join a Wi-Fi network itself (Android 10+).
bool get canJoinPrinterNetwork => Platform.isAndroid;

const _channel = MethodChannel('offprint/wifi');

/// Asks Android to join the printer's network and routes the app's traffic
/// through it. Android shows its own confirmation dialog.
Future<void> joinPrinterNetwork(PrinterNetwork n) async {
  try {
    await _channel.invokeMethod<bool>('connect', {'ssid': n.ssid, 'password': n.password, 'wpa3': n.wpa3});
  } on PlatformException catch (e) {
    throw Exception(e.message ?? 'Could not join ${n.ssid}');
  }
}

/// Releases the printer network so the phone returns to its normal Wi-Fi.
Future<void> leavePrinterNetwork() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<void>('disconnect');
  } on PlatformException {
    // nothing joined
  }
}
