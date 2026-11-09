/// Printer connection settings, status, and the print pipeline.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cpnp.dart';
import 'ipp.dart';
import 'models.dart';
import 'render.dart';

enum Transport {
  wifi('Wi-Fi (full features)'),
  usb('USB cable'),
  ippNetwork('Network (standard IPP)');

  const Transport(this.label);
  final String label;
}

class PrinterInfo {
  const PrinterInfo({required this.online, required this.summary, this.detail = '', this.idle});
  final bool online;
  final String summary;
  final String detail;
  final IdleStatus? idle;
}

enum PrintPhase { rendering, connecting, sending, printing, done, failed }

class PrintProgress {
  const PrintProgress(this.phase, this.message, {this.fraction, this.sheet = 0, this.sheets = 0});
  final PrintPhase phase;
  final String message;
  final double? fraction;
  final int sheet, sheets;
}

class HistoryEntry {
  HistoryEntry({required this.time, required this.paper, required this.layout, required this.surface,
      required this.sheets, required this.thumb, required this.transport});

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        time: DateTime.parse(j['time'] as String),
        paper: j['paper'] as String,
        layout: j['layout'] as String,
        surface: j['surface'] as String,
        sheets: j['sheets'] as int,
        thumb: j['thumb'] as String,
        transport: j['transport'] as String? ?? '',
      );

  final DateTime time;
  final String paper, layout, surface, thumb, transport;
  final int sheets;

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(), 'paper': paper, 'layout': layout, 'surface': surface,
        'sheets': sheets, 'thumb': thumb, 'transport': transport,
      };
}

/// App-wide printer state (ChangeNotifier so widgets can listen).
class PrinterService extends ChangeNotifier {
  Transport transport = Transport.wifi;
  String host = '';
  String ippUri = usbIppUri;
  PrinterInfo info = const PrinterInfo(online: false, summary: 'Not checked');
  List<HistoryEntry> history = [];
  bool busy = false;
  late Directory _dataDir;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    transport = Transport.values.asNameMap()[prefs.getString('transport')] ??
        (Platform.isLinux ? Transport.usb : Transport.wifi);
    host = prefs.getString('host') ?? '';
    ippUri = prefs.getString('ippUri') ?? usbIppUri;
    _dataDir = await getApplicationSupportDirectory();
    final f = File('${_dataDir.path}/history.json');
    if (await f.exists()) {
      try {
        history = (jsonDecode(await f.readAsString()) as List).map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        history = [];
      }
    }
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> save({Transport? transport, String? host, String? ippUri}) async {
    if (transport != null) this.transport = transport;
    if (host != null) this.host = host.trim();
    if (ippUri != null) this.ippUri = ippUri.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('transport', this.transport.name);
    await prefs.setString('host', this.host);
    await prefs.setString('ippUri', this.ippUri);
    notifyListeners();
    await refresh();
  }

  String get _ippTarget => transport == Transport.usb ? usbIppUri : ippUri;

  /// Re-reads printer status. Auto-discovers a Wi-Fi printer if no host is set.
  Future<void> refresh() async {
    try {
      switch (transport) {
        case Transport.wifi:
          if (host.isEmpty) {
            final found = await discover();
            if (found.isEmpty) {
              info = const PrinterInfo(online: false, summary: 'No printer found on Wi-Fi');
              break;
            }
            host = found.first.address;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('host', host);
          }
          final st = await SelphyCpnp(host).idleStatus();
          info = PrinterInfo(
            online: true,
            summary: st.stateName,
            detail: 'Ink ${st.inkName} · Tray ${st.trayName} · ${st.powerName} · fw ${st.firmware}',
            idle: st,
          );
        case Transport.usb || Transport.ippNetwork:
          final s = await IppPrinter(_ippTarget).printerState();
          info = PrinterInfo(online: true, summary: s, detail: _ippTarget);
      }
    } catch (e) {
      info = PrinterInfo(online: false, summary: 'Offline', detail: '$e');
    }
    notifyListeners();
  }

  /// Renders and prints every sheet of [job] × copies.
  Stream<PrintProgress> print(PrintJob job) async* {
    if (busy) {
      yield const PrintProgress(PrintPhase.failed, 'Already printing');
      return;
    }
    busy = true;
    notifyListeners();
    final total = job.sheetCount * job.copies;
    try {
      if (job.hasDesign && transport != Transport.wifi) {
        throw Exception('Custom overcoat designs need the Wi-Fi connection.');
      }
      final rendered = <RenderedSheet>[];
      for (var i = 0; i < job.sheetCount; i++) {
        yield PrintProgress(PrintPhase.rendering, 'Preparing sheet ${i + 1} of ${job.sheetCount}',
            fraction: i / job.sheetCount, sheets: total);
        rendered.add(await renderSheet(job, i, portraitForIpp: transport != Transport.wifi));
      }

      if (transport == Transport.wifi) {
        yield* _printCpnp(job, rendered);
      } else {
        yield* _printIpp(job, rendered);
      }
      await _remember(job);
      yield PrintProgress(PrintPhase.done, total == 1 ? 'Printed' : 'Printed $total sheets', fraction: 1, sheets: total);
    } catch (e) {
      yield PrintProgress(PrintPhase.failed, '$e');
    } finally {
      busy = false;
      notifyListeners();
      unawaited(refresh());
    }
  }

  Stream<PrintProgress> _printCpnp(PrintJob job, List<RenderedSheet> rendered) async* {
    if (host.isEmpty) {
      await refresh();
      if (host.isEmpty) throw CpnpException('No printer found on Wi-Fi');
    }
    final printer = SelphyCpnp(host);
    final sheets = [
      for (var c = 0; c < job.copies; c++)
        for (final r in rendered)
          CpnpSheet(
            jpeg: r.jpeg, width: r.width, height: r.height, paperCode: job.paper.cpnpSize,
            finish: job.surface.finish.code, autoCorrect: job.autoCorrect,
            mask: r.mask, maskWidth: job.paper.maskWidth, maskHeight: job.paper.maskHeight,
          ),
    ];
    var done = 0;
    for (var start = 0; start < sheets.length; start += maxSheetsPerJob) {
      final batch = sheets.sublist(start, (start + maxSheetsPerJob).clamp(0, sheets.length));
      final events = StreamController<PrintProgress>();
      final send = printer.printSheets(batch, onProgress: (p) {
        events.add(PrintProgress(PrintPhase.sending, p.message, fraction: p.fraction, sheet: done + 1, sheets: sheets.length));
      }).whenComplete(events.close);
      yield PrintProgress(PrintPhase.connecting, 'Connecting to $host', sheets: sheets.length);
      yield* events.stream;
      await send;

      await for (final st in printer.watchPrinting()) {
        if (st.error != 0) {
          yield PrintProgress(PrintPhase.printing, errorMessage(st.error), sheet: done + 1, sheets: sheets.length);
          if (!isRecoverable(st.error)) throw CpnpException(errorMessage(st.error), st.error);
        } else if (st.busy) {
          yield PrintProgress(PrintPhase.printing, 'Printing…', sheet: done + 1, sheets: sheets.length);
        }
      }
      done += batch.length;
    }
  }

  Stream<PrintProgress> _printIpp(PrintJob job, List<RenderedSheet> rendered) async* {
    final printer = IppPrinter(_ippTarget);
    for (var i = 0; i < rendered.length; i++) {
      yield PrintProgress(PrintPhase.sending, 'Sending sheet ${i + 1}', sheet: i + 1, sheets: rendered.length);
      final id = await printer.printJpeg(rendered[i].jpeg, job.paper, copies: job.copies, name: 'Offprint ${i + 1}');
      while (true) {
        final state = await printer.jobState(id);
        if (state == 'completed') break;
        if (state == 'canceled' || state == 'aborted') throw IppException('Job $state');
        yield PrintProgress(PrintPhase.printing, 'Printing ($state)…', sheet: i + 1, sheets: rendered.length);
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _remember(PrintJob job) async {
    try {
      final thumbs = Directory('${_dataDir.path}/thumbs');
      await thumbs.create(recursive: true);
      final now = DateTime.now();
      final file = File('${thumbs.path}/${now.millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(await thumbnail(job, 0));
      history.insert(0, HistoryEntry(
        time: now, paper: job.paper.name, layout: job.layout.label,
        surface: job.hasDesign ? 'Custom design' : job.surface.label,
        sheets: job.sheetCount * job.copies, thumb: file.path, transport: transport.label,
      ));
      await File('${_dataDir.path}/history.json').writeAsString(jsonEncode(history.map((e) => e.toJson()).toList()));
      notifyListeners();
    } catch (e) {
      debugPrint('history: $e');
    }
  }

  int get totalSheets => history.fold(0, (a, e) => a + e.sheets);

  Future<void> clearHistory() async {
    for (final h in history) {
      try {
        await File(h.thumb).delete();
      } catch (_) {}
    }
    history = [];
    await File('${_dataDir.path}/history.json').writeAsString('[]');
    notifyListeners();
  }
}

