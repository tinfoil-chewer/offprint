/// Canon Photo Network Protocol (CPNP) client for SELPHY CP-series printers.
///
/// Reverse-engineered from SELPHY Photo Layout 4.4.0; verified against a CP1500.
/// Port of cli/selphy/cpnp.py — see docs/PROTOCOL.md for the wire format.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const cpnpPort = 8609;
const _magic = [0x43, 0x50, 0x4E, 0x50]; // "CPNP"
const _req = 0x01, _resp = 0x81;
const _sessionUser = 'SPL v2.0';
const _sessionDocument = 'Square';
const _defaultMaxWrite = 0x8400;
const maxSheetsPerJob = 20;

abstract final class Cmd {
  static const deviceId = 0x30;
  static const sessionStart = 0x10;
  static const sessionEnd = 0x11;
  static const read = 0x20;
  static const write = 0x21;
  static const getMaxWrite = 0x51;
  static const setMaxWrite = 0x52;
}

abstract final class DataRequest {
  static const none = 0;
  static const startPrint = 0x10000;
  static const printData = 0x20000;
  static const ocData = 0x2FFFF;
  static const endPrint = 0x30000;
  static const cancelPrint = 0x40000;
  static const executeSpoolPrint = 0x70000;
}

const deviceStatusNames = <int, String>{
  0x0000: 'Idle',
  0x00F0: 'Finishing',
  0xFF00: 'Cancelling',
  0xFF01: 'Preparing',
  0xFF02: 'Heating (yellow)',
  0xFF03: 'Printing yellow',
  0xFF04: 'Heating (magenta)',
  0xFF05: 'Printing magenta',
  0xFF06: 'Heating (cyan)',
  0xFF07: 'Printing cyan',
  0xFF08: 'Heating (overcoat)',
  0xFF09: 'Applying overcoat',
  0xFF0A: 'Finishing',
  0xFF0B: 'Warming battery',
  0xFF0C: 'Paused (error)',
  0xFF0D: 'Waiting to resume',
  0xFF10: 'Feeding paper',
  0xFFFF: 'Critical error',
};

const errorMessages = <int, String>{
  0: 'No error',
  266: 'Waiting for paper',
  0x10101: 'Out of paper',
  0x10102: 'Paper tray missing',
  0x10103: 'Paper tray size differs from ink cassette',
  0x10106: 'Paper problem (width)',
  0x10107: 'Paper problem (height)',
  0x10109: 'Paper cover open',
  0x1010B: 'Paper feed problem',
  0x1010C: 'Different paper size',
  0x1010D: 'Paper set incorrectly',
  0x10201: 'Ink ribbon used up',
  0x10202: 'No ink cassette',
  0x10203: 'Ink cassette size differs',
  0x10204: 'Ink cassette type differs',
  0x10205: 'Unknown ink cassette',
  0x10302: 'No paper tray and no ink cassette',
  0x10303: 'Paper tray and ink cassette mismatch',
  0x1FF03: 'Low battery',
  0x3FF05: 'Image could not be decoded',
  0xFF0104: 'Paper jam',
  0xFF0202: 'No ink cassette',
  0xFF0206: 'Ink problem',
  0xFFFF00: 'Printer error',
  0xFFFF04: 'Command error',
  0xFFFF07: 'Battery error',
};

String errorMessage(int code) =>
    errorMessages[code] ?? 'Error 0x${code.toRadixString(16).padLeft(6, '0')}';

/// Recoverable errors (printer waits for the user, e.g. paper out).
bool isRecoverable(int error) => (error & 0xFFFF0000) == 0x10000;

const cassetteNames = <int, String>{
  0: 'Unknown', 1: 'None', 2: 'Card', 3: 'L', 4: 'Postcard', 5: 'Postcard (54)', 6: 'Postcard HD',
};

class CpnpException implements Exception {
  CpnpException(this.message, [this.code]);
  final String message;
  final int? code;
  @override
  String toString() => message;
}

Uint8List _header(int cmd, int packetId, [int sessionId = 0, int length = 0]) {
  final b = ByteData(16);
  for (var i = 0; i < 4; i++) {
    b.setUint8(i, _magic[i]);
  }
  b
    ..setUint8(4, _req)
    ..setUint8(5, cmd)
    ..setUint16(8, packetId)
    ..setUint16(10, sessionId)
    ..setUint32(12, length);
  return b.buffer.asUint8List();
}

class _Response {
  _Response(this.raw)
      : error = ByteData.sublistView(raw).getUint16(6),
        sessionId = ByteData.sublistView(raw).getUint16(10),
        length = ByteData.sublistView(raw).getUint32(12);
  final Uint8List raw;
  final int error, sessionId, length;
  Uint8List get payload => Uint8List.sublistView(raw, 16, (16 + length).clamp(16, raw.length));
  int u32be(int offset) => ByteData.sublistView(raw).getUint32(offset);
  int u16be(int offset) => ByteData.sublistView(raw).getUint16(offset);
}

int _find(Uint8List data, int cmd) {
  for (var i = 0; i + 16 <= data.length; i++) {
    if (data[i] == 0x43 && data[i + 1] == 0x50 && data[i + 2] == 0x4E && data[i + 3] == 0x50 &&
        data[i + 4] == _resp && data[i + 5] == cmd) {
      return i;
    }
  }
  return -1;
}

_Response _parse(Uint8List data, int cmd) {
  final i = _find(data, cmd);
  if (i < 0) throw CpnpException('Unexpected reply to command 0x${cmd.toRadixString(16)}');
  return _Response(Uint8List.sublistView(data, i));
}

int _le(Uint8List b, int o, int n) {
  var v = 0;
  for (var i = 0; i < n; i++) {
    v |= b[o + i] << (8 * i);
  }
  return v;
}

void _putLe(Uint8List b, int o, int n, int v) {
  for (var i = 0; i < n; i++) {
    b[o + i] = (v >> (8 * i)) & 0xFF;
  }
}

/// Status available without a session (UDP Read, 512 bytes).
class IdleStatus {
  IdleStatus._(this.state, this.paperTray, this.inkCassette, this.power, this.battery, this.error,
      this.firmware);

  factory IdleStatus.parse(Uint8List b) {
    if (b.length < 140) throw CpnpException('Status reply too short');
    final ext = String.fromCharCodes(b.sublist(80, 84)).split('').join('.');
    return IdleStatus._(b[0], b[2], b[3], b[66], b[67], _le(b, 68, 4), '$ext (${b[84]}.${b[86]})');
  }

  /// 1 idle, 2 busy, 241 error.
  final int state;
  final int paperTray, inkCassette, power, battery, error;
  final String firmware;

  bool get idle => state == 1;
  bool get busy => state == 2;
  bool get hasError => state == 241 || error != 0;
  String get trayName => cassetteNames[paperTray] ?? 'Unknown';
  String get inkName => cassetteNames[inkCassette] ?? 'Unknown';
  String get powerName => const {0: 'AC adapter', 1: 'Battery', 2: 'USB power'}[power] ?? '?';
  String get stateName => hasError ? errorMessage(error) : (busy ? 'Printing' : 'Ready');
}

/// Status read through an open session.
class JobStatus {
  JobStatus.parse(Uint8List b)
      : deviceType = b[2],
        status = _le(b, 8, 2),
        error = _le(b, 12, 4),
        dataRequest = _le(b, 16, 4),
        retry = _le(b, 20, 4),
        offset = _le(b, 24, 4),
        size = _le(b, 28, 4),
        spooled = b[40],
        printed = b[41];

  final int deviceType, status, error, dataRequest, retry, offset, size, spooled, printed;

  bool get isPrintData => (dataRequest & 0xFFFFFF00) == DataRequest.printData;
  bool get isOcData => (dataRequest | 0xFF) == DataRequest.ocData;
  int get page => dataRequest & 0xFF;
  String get statusName => deviceStatusNames[status] ?? '0x${status.toRadixString(16)}';
  String get requestKey => '$dataRequest/$retry/$offset/$size';
}

/// One sheet ready for CPNP.
class CpnpSheet {
  CpnpSheet({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.paperCode,
    this.finish = 2,
    this.autoCorrect = false,
    this.mask,
    this.maskWidth = 0,
    this.maskHeight = 0,
  });
  final Uint8List jpeg;
  final int width, height, paperCode, finish;
  final bool autoCorrect;
  final Uint8List? mask;
  final int maskWidth, maskHeight;
}

// ---- print commands (little-endian, inside Write payloads) ----
const _codePrintData = 1, _codeCancel = 2, _codeEnd = 3, _codeOcData = 5;
const _codeStartSpool = 7, _codeExecuteSpool = 8;
const _transferHeader = 104;

Uint8List makeStartSpool(List<CpnpSheet> sheets) {
  final first = sheets.first;
  final b = Uint8List(192);
  _putLe(b, 2, 2, _codeStartSpool);
  _putLe(b, 4, 4, 192);
  _putLe(b, 12, 2, sheets.length.clamp(1, maxSheetsPerJob));
  _putLe(b, 14, 2, first.paperCode);
  b[16] = 1; // overcoat per page
  b[17] = first.autoCorrect ? 3 : 2;
  b[18] = 2; // borderless; borders are drawn into the image
  b[19] = first.finish;
  for (var i = 0; i < sheets.length && i < maxSheetsPerJob; i++) {
    _putLe(b, 32 + 8 * i, 4, sheets[i].jpeg.length);
    final m = sheets[i].mask;
    if (m != null) _putLe(b, 36 + 8 * i, 4, m.length);
  }
  return b;
}

Uint8List makeSimple(int code) {
  final b = Uint8List(64);
  _putLe(b, 2, 2, code);
  _putLe(b, 4, 4, 64);
  return b;
}

Uint8List makePrintData(CpnpSheet s, int offset, int size) {
  final end = (offset + size).clamp(0, s.jpeg.length);
  final chunk = Uint8List.sublistView(s.jpeg, offset.clamp(0, s.jpeg.length), end);
  final b = Uint8List(_transferHeader + chunk.length);
  _putLe(b, 2, 2, _codePrintData);
  _putLe(b, 4, 4, b.length);
  _putLe(b, 12, 4, 1);
  _putLe(b, 20, 4, s.jpeg.length);
  _putLe(b, 24, 4, s.width);
  _putLe(b, 28, 4, s.height);
  b[32] = s.mask != null ? 255 : 2;
  _putLe(b, 96, 4, offset);
  _putLe(b, 100, 4, chunk.length);
  b.setRange(_transferHeader, b.length, chunk);
  return b;
}

Uint8List makeOcData(CpnpSheet s, int offset, int size) {
  final m = s.mask!;
  final end = (offset + size).clamp(0, m.length);
  final chunk = Uint8List.sublistView(m, offset.clamp(0, m.length), end);
  final b = Uint8List(_transferHeader + chunk.length);
  _putLe(b, 2, 2, _codeOcData);
  _putLe(b, 4, 4, b.length);
  _putLe(b, 8, 4, 1);
  _putLe(b, 12, 4, m.length);
  _putLe(b, 16, 4, s.maskWidth);
  _putLe(b, 20, 4, s.maskHeight);
  _putLe(b, 96, 4, offset);
  _putLe(b, 100, 4, chunk.length);
  b.setRange(_transferHeader, b.length, chunk);
  return b;
}

/// A printer that answered discovery.
class FoundPrinter {
  FoundPrinter(this.address, this.deviceId);
  final String address;
  final Map<String, String> deviceId;
  String get model => deviceId['MDL'] ?? deviceId['DES'] ?? 'SELPHY';
}

Map<String, String> _parseDeviceId(String s) => {
      for (final part in s.split(';'))
        if (part.contains(':')) part.substring(0, part.indexOf(':')).trim(): part.substring(part.indexOf(':') + 1).trim(),
    };

String _deviceIdText(_Response r) {
  final p = r.payload;
  if (p.length <= 2) return '';
  var end = p.indexOf(0, 2);
  if (end < 0) end = p.length;
  return ascii.decode(p.sublist(2, end), allowInvalid: true);
}

/// Broadcasts a DeviceId request on the LAN.
Future<List<FoundPrinter>> discover({Duration timeout = const Duration(seconds: 2)}) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sock.broadcastEnabled = true;
  final found = <String, FoundPrinter>{};
  final sub = sock.listen((e) {
    if (e != RawSocketEvent.read) return;
    final dg = sock.receive();
    if (dg == null) return;
    try {
      final r = _parse(dg.data, Cmd.deviceId);
      found[dg.address.address] = FoundPrinter(dg.address.address, _parseDeviceId(_deviceIdText(r)));
    } on CpnpException {
      // not a printer reply
    }
  });
  final pkt = BytesBuilder()
    ..add(_header(Cmd.deviceId, 1, 0, 4))
    ..add(Uint8List(4));
  sock.send(pkt.toBytes(), InternetAddress('255.255.255.255'), cpnpPort);
  await Future<void>.delayed(timeout);
  await sub.cancel();
  sock.close();
  return found.values.toList();
}

/// Buffered packet reader over the session TCP socket.
class _TcpChannel {
  _TcpChannel(this.socket) {
    _sub = socket.listen(_onData, onError: _onError, onDone: () => _onError(CpnpException('Printer closed the connection')));
  }
  final Socket socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  Completer<Uint8List>? _waiter;
  Object? _error;

  void _onData(Uint8List d) {
    _buf.add(d);
    _tryComplete();
  }

  void _onError(Object e) {
    _error = e;
    final w = _waiter;
    _waiter = null;
    w?.completeError(e);
  }

  void _tryComplete() {
    if (_waiter == null) return;
    if (_buf.length > 0) {
      _pending = Uint8List.fromList([..._pending, ..._buf.takeBytes()]);
    }
    final start = _pending.indexOf(0x43);
    for (var i = start < 0 ? _pending.length : start; i + 16 <= _pending.length; i++) {
      if (_pending[i] == 0x43 && _pending[i + 1] == 0x50 && _pending[i + 2] == 0x4E && _pending[i + 3] == 0x50) {
        final len = ByteData.sublistView(_pending).getUint32(i + 12);
        if (_pending.length - i >= 16 + len) {
          final pkt = Uint8List.fromList(_pending.sublist(i, i + 16 + len));
          _pending = Uint8List.fromList(_pending.sublist(i + 16 + len));
          final w = _waiter!;
          _waiter = null;
          w.complete(pkt);
        }
        return;
      }
    }
  }

  Future<Uint8List> next(Duration timeout) {
    if (_error != null) return Future.error(_error!);
    _waiter = Completer<Uint8List>();
    final f = _waiter!.future;
    _tryComplete();
    return f.timeout(timeout, onTimeout: () {
      _waiter = null;
      throw CpnpException('Printer stopped responding');
    });
  }

  Future<void> close() async {
    await _sub.cancel();
    socket.destroy();
  }
}

/// Progress events while sending a job.
class CpnpProgress {
  CpnpProgress(this.message, {this.sent = 0, this.total = 0, this.status});
  final String message;
  final int sent, total;
  final JobStatus? status;
  double? get fraction => total == 0 ? null : sent / total;
}

class SelphyCpnp {
  SelphyCpnp(this.host, {this.timeout = const Duration(seconds: 3), this.clientName = 'Offprint'});

  final String host;
  final Duration timeout;
  final String clientName;
  int _pid = 1;
  int _session = 0;
  int _maxWrite = 4096;
  _TcpChannel? _tcp;

  int _nextPid() => _pid = _pid < 0x7FFF ? _pid + 1 : 1;

  Future<_Response> _udp(Uint8List packet, int cmd) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      try {
        final completer = Completer<_Response>();
        final sub = sock.listen((e) {
          if (e != RawSocketEvent.read || completer.isCompleted) return;
          final dg = sock.receive();
          if (dg == null) return;
          try {
            completer.complete(_parse(dg.data, cmd));
          } on CpnpException catch (err) {
            last = err;
          }
        });
        sock.send(packet, InternetAddress(host), cpnpPort);
        try {
          return await completer.future.timeout(timeout);
        } on TimeoutException catch (e) {
          last = e;
        } finally {
          await sub.cancel();
        }
      } finally {
        sock.close();
      }
    }
    throw CpnpException('No reply from printer at $host ($last)');
  }

  Future<Map<String, String>> deviceId() async {
    final pkt = BytesBuilder()
      ..add(_header(Cmd.deviceId, _nextPid(), 0, 4))
      ..add(Uint8List(4));
    return _parseDeviceId(_deviceIdText(await _udp(pkt.toBytes(), Cmd.deviceId)));
  }

  Future<IdleStatus> idleStatus() async =>
      IdleStatus.parse((await _udp(_header(Cmd.read, _nextPid()), Cmd.read)).payload);

  Future<void> open({Duration wait = const Duration(seconds: 30)}) async {
    var retry = 0, stamp = 0, port = 0;
    final deadline = DateTime.now().add(wait);
    while (true) {
      final pkt = Uint8List(408);
      pkt.setRange(0, 16, _header(Cmd.sessionStart, _nextPid(), 0, 392));
      ByteData.sublistView(pkt)
        ..setUint32(16, retry)
        ..setUint32(20, stamp);
      void putUtf16(int off, String s, int max) {
        final units = s.codeUnits;
        for (var i = 0; i < units.length && 2 * i + 1 < max; i++) {
          pkt[off + 2 * i] = units[i] >> 8;
          pkt[off + 2 * i + 1] = units[i] & 0xFF;
        }
      }

      putUtf16(24, clientName, 64);
      putUtf16(88, _sessionUser, 64);
      putUtf16(152, _sessionDocument, 64);
      final r = await _udp(pkt, Cmd.sessionStart);
      if (r.error == 0) {
        _session = r.sessionId;
        port = r.u16be(20);
        break;
      }
      if ((r.error != 0x8501 && r.error != 0x8502) || DateTime.now().isAfter(deadline)) {
        throw CpnpException('Printer is busy with another device', r.error);
      }
      retry++;
      stamp = r.u32be(16);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (_session == 0 || port == 0) throw CpnpException('Printer refused the session');
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _tcp = _TcpChannel(socket);
    try {
      final v = ByteData(4)..setUint32(0, _defaultMaxWrite);
      await _call(Cmd.setMaxWrite, v.buffer.asUint8List());
    } on CpnpException {
      // keep default
    }
    try {
      final r = await _call(Cmd.getMaxWrite);
      final v = r.u32be(16);
      _maxWrite = v > 0 ? v : 4096;
    } on CpnpException {
      _maxWrite = 4096;
    }
  }

  Future<void> close() async {
    await _tcp?.close();
    _tcp = null;
    if (_session != 0) {
      try {
        await _udp(_header(Cmd.sessionEnd, _nextPid(), _session), Cmd.sessionEnd);
      } on CpnpException {
        // ignore
      }
      _session = 0;
    }
  }

  Future<_Response> _call(int cmd, [Uint8List? payload]) async {
    final tcp = _tcp;
    if (tcp == null) throw CpnpException('Not connected');
    final p = payload ?? Uint8List(0);
    tcp.socket
      ..add(_header(cmd, _nextPid(), _session, p.length))
      ..add(p);
    final r = _parse(await tcp.next(const Duration(seconds: 15)), cmd);
    if (r.error != 0) throw CpnpException('Command 0x${cmd.toRadixString(16)} failed (0x${r.error.toRadixString(16)})', r.error);
    return r;
  }

  Future<JobStatus> jobStatus() async {
    for (var i = 0; i < 100; i++) {
      final r = await _call(Cmd.read);
      if (r.payload.length >= 64) return JobStatus.parse(r.payload);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw CpnpException('Printer sent no status');
  }

  Future<void> write(Uint8List data, [void Function(int bytes)? onBytes]) async {
    var sent = 0;
    while (sent < data.length) {
      final block = (data.length - sent).clamp(0, _maxWrite);
      var accepted = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (accepted < block) {
        final r = await _call(Cmd.write, Uint8List.sublistView(data, sent + accepted, sent + block));
        accepted += r.u32be(16);
        if (accepted < block) {
          if (DateTime.now().isAfter(deadline)) throw CpnpException('Printer stopped accepting data');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      sent += block;
      onBytes?.call(block);
    }
  }

  /// Sends up to 20 sheets (same paper/finish). Completes once the printer has
  /// all data; printing then continues on the printer — follow it with
  /// [watchPrinting].
  Future<void> printSheets(List<CpnpSheet> sheets, {void Function(CpnpProgress)? onProgress}) async {
    if (sheets.isEmpty || sheets.length > maxSheetsPerJob) {
      throw ArgumentError('1..$maxSheetsPerJob sheets per job');
    }
    final idle = await idleStatus();
    if (idle.error != 0) throw CpnpException(errorMessage(idle.error), idle.error);

    final total = sheets.fold<int>(0, (a, s) => a + s.jpeg.length + (s.mask?.length ?? 0));
    var sent = 0;
    onProgress?.call(CpnpProgress('Connecting…', total: total));
    await open();
    try {
      var deadline = DateTime.now().add(const Duration(minutes: 2));
      while ((await jobStatus()).dataRequest != DataRequest.startPrint) {
        if (DateTime.now().isAfter(deadline)) throw CpnpException('Printer never became ready');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await write(makeStartSpool(sheets));

      String? lastKey;
      final requested = <int>{};
      while (true) {
        final st = await jobStatus();
        if (st.status == 0x00F0) return;
        if (st.error != 0 && !isRecoverable(st.error)) throw CpnpException(errorMessage(st.error), st.error);
        if (st.error != 0) {
          onProgress?.call(CpnpProgress(errorMessage(st.error), sent: sent, total: total, status: st));
        }
        final key = st.requestKey;
        if (key != lastKey && (st.isPrintData || st.isOcData)) {
          lastKey = key;
          final sheet = sheets[st.page];
          requested.add(st.page);
          final cmd = st.isPrintData ? makePrintData(sheet, st.offset, st.size) : makeOcData(sheet, st.offset, st.size);
          final label = st.isPrintData ? 'Sending photo' : 'Sending overcoat design';
          final payload = cmd.length - _transferHeader;
          await write(cmd);
          sent += payload;
          onProgress?.call(CpnpProgress('$label ${st.page + 1}/${sheets.length}', sent: sent, total: total, status: st));
          deadline = DateTime.now().add(const Duration(minutes: 2));
          continue;
        }
        if (st.dataRequest == DataRequest.executeSpoolPrint) {
          if (requested.length >= sheets.length) return;
          if (key != lastKey) {
            lastKey = key;
            await write(makeSimple(_codeExecuteSpool));
          }
        } else if (st.dataRequest == DataRequest.endPrint && key != lastKey) {
          lastKey = key;
          await write(makeSimple(_codeEnd));
        } else if (st.dataRequest == DataRequest.startPrint && requested.isNotEmpty) {
          return;
        }
        if (DateTime.now().isAfter(deadline)) throw CpnpException('Timed out (${st.statusName})');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      await close();
    }
  }

  /// Polls idle status until the printer is idle again (or errors).
  Stream<IdleStatus> watchPrinting({Duration timeout = const Duration(minutes: 10)}) async* {
    final end = DateTime.now().add(timeout);
    var sawBusy = false;
    var idleCount = 0;
    while (DateTime.now().isBefore(end)) {
      IdleStatus st;
      try {
        st = await idleStatus();
      } on CpnpException {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      yield st;
      if (st.busy) sawBusy = true;
      if (st.idle && st.error == 0) {
        idleCount++;
        if (sawBusy || idleCount > 5) return;
      }
      if (st.error != 0 && !isRecoverable(st.error)) return;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> cancel() async {
    await open();
    try {
      await write(makeSimple(_codeCancel));
    } finally {
      await close();
    }
  }
}
