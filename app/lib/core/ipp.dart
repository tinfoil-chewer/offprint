/// Minimal IPP/2.0 client: print a JPEG, query printer and job state.
///
/// USB on Linux goes through ipp-usb: ipp://localhost:60000/ipp/print
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'media.dart';

const usbIppUri = 'ipp://localhost:60000/ipp/print';

class IppException implements Exception {
  IppException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract final class _Tag {
  static const op = 0x01, job = 0x02, end = 0x03;
  static const integer = 0x21, boolean = 0x22, enumT = 0x23;
  static const range = 0x33, resolution = 0x32;
  static const begColl = 0x34, endColl = 0x37, member = 0x4A;
  static const name = 0x42, keyword = 0x44, uri = 0x45, charset = 0x47, lang = 0x48, mime = 0x49;
}

const jobStates = {3: 'pending', 4: 'held', 5: 'processing', 6: 'stopped', 7: 'canceled', 8: 'aborted', 9: 'completed'};

class _Enc {
  final b = BytesBuilder();
  void attr(int tag, String name, List<int> value) {
    final n = utf8.encode(name);
    b
      ..add([tag, n.length >> 8, n.length & 0xFF])
      ..add(n)
      ..add([value.length >> 8, value.length & 0xFF])
      ..add(value);
  }

  void str(int tag, String name, String v) => attr(tag, name, utf8.encode(v));
  void integer(String name, int v, [int tag = _Tag.integer]) =>
      attr(tag, name, (ByteData(4)..setInt32(0, v)).buffer.asUint8List());
  void member(int tag, String name, List<int> v) {
    attr(_Tag.member, '', utf8.encode(name));
    attr(tag, '', v);
  }

  List<int> i32(int v) => (ByteData(4)..setInt32(0, v)).buffer.asUint8List();
}

class IppPrinter {
  IppPrinter(this.uri, {this.user = 'offprint'});
  final String uri;
  final String user;
  int _rid = 0;

  Uri get _http {
    final u = Uri.parse(uri);
    return Uri(scheme: 'http', host: u.host, port: u.hasPort ? u.port : 631, path: u.path.isEmpty ? '/ipp/print' : u.path);
  }

  Future<(int, Map<String, List<Object>>)> _request(int op, void Function(_Enc) opAttrs,
      {void Function(_Enc)? jobAttrs, Uint8List? data}) async {
    final e = _Enc();
    e.b.add((ByteData(8)
          ..setUint8(0, 2)
          ..setUint8(1, 0)
          ..setUint16(2, op)
          ..setUint32(4, ++_rid))
        .buffer
        .asUint8List());
    e.b.addByte(_Tag.op);
    e.str(_Tag.charset, 'attributes-charset', 'utf-8');
    e.str(_Tag.lang, 'attributes-natural-language', 'en');
    e.str(_Tag.uri, 'printer-uri', uri);
    e.str(_Tag.name, 'requesting-user-name', user);
    opAttrs(e);
    if (jobAttrs != null) {
      e.b.addByte(_Tag.job);
      jobAttrs(e);
    }
    e.b.addByte(_Tag.end);
    if (data != null) e.b.add(data);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(_http);
      req.headers.contentType = ContentType('application', 'ipp');
      final body = e.b.takeBytes();
      req.contentLength = body.length;
      req.add(body);
      final resp = await req.close().timeout(const Duration(seconds: 60));
      final bytes = await resp.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d)).then((b) => b.takeBytes());
      if (resp.statusCode != 200) throw IppException('HTTP ${resp.statusCode}');
      final (status, attrs) = _parse(bytes);
      if (status >= 0x400) {
        final msg = attrs['status-message']?.first ?? '';
        throw IppException('Printer rejected the request (0x${status.toRadixString(16)}) $msg');
      }
      return (status, attrs);
    } on SocketException catch (err) {
      throw IppException('Cannot reach printer: ${err.message}');
    } finally {
      client.close();
    }
  }

  static (int, Map<String, List<Object>>) _parse(Uint8List body) {
    if (body.length < 8) throw IppException('Short IPP response');
    final bd = ByteData.sublistView(body);
    final status = bd.getUint16(2);
    final attrs = <String, List<Object>>{};
    var i = 8, depth = 0;
    var name = '';
    while (i < body.length) {
      final tag = body[i++];
      if (tag == _Tag.end) break;
      if (tag < 0x10) continue;
      final nl = bd.getUint16(i);
      i += 2;
      final n = utf8.decode(body.sublist(i, i + nl));
      i += nl;
      final vl = bd.getUint16(i);
      i += 2;
      final v = body.sublist(i, i + vl);
      i += vl;
      if (tag == _Tag.begColl) {
        depth++;
        continue;
      }
      if (tag == _Tag.endColl) {
        depth--;
        continue;
      }
      if (depth > 0) continue;
      if (n.isNotEmpty) name = n;
      final Object value = switch (tag) {
        _Tag.integer || _Tag.enumT => ByteData.sublistView(v).getInt32(0),
        _Tag.boolean => v.first != 0,
        _Tag.range || _Tag.resolution => v,
        _ when tag >= 0x40 => utf8.decode(v, allowMalformed: true),
        _ => v,
      };
      attrs.putIfAbsent(name, () => []).add(value);
    }
    return (status, attrs);
  }

  Future<Map<String, List<Object>>> attributes([List<String> names = const ['all']]) async {
    final (_, a) = await _request(0x0B, (e) {
      for (var k = 0; k < names.length; k++) {
        e.str(_Tag.keyword, k == 0 ? 'requested-attributes' : '', names[k]);
      }
    });
    return a;
  }

  void _jobAttrs(_Enc e, Paper paper, int copies, bool color) {
    e
      ..integer('copies', copies)
      ..str(_Tag.keyword, 'print-color-mode', color ? 'color' : 'monochrome')
      ..str(_Tag.keyword, 'print-scaling', 'fill')
      ..attr(_Tag.begColl, 'media-col', []);
    e.attr(_Tag.member, '', utf8.encode('media-size'));
    e.attr(_Tag.begColl, '', []);
    e.member(_Tag.integer, 'x-dimension', e.i32(paper.ippWidth));
    e.member(_Tag.integer, 'y-dimension', e.i32(paper.ippHeight));
    e.attr(_Tag.endColl, '', []);
    for (final side in ['top', 'bottom', 'left', 'right']) {
      e.member(_Tag.integer, 'media-$side-margin', e.i32(0));
    }
    e.member(_Tag.keyword, 'media-type', utf8.encode('photographic'));
    e.member(_Tag.keyword, 'media-source', utf8.encode('photo'));
    e.attr(_Tag.endColl, '', []);
  }

  /// [jpeg] must be portrait (IPP media sizes are portrait).
  Future<int> printJpeg(Uint8List jpeg, Paper paper, {int copies = 1, bool color = true, String name = 'photo'}) async {
    final (_, a) = await _request(0x02, (e) {
      e
        ..str(_Tag.name, 'job-name', name)
        ..str(_Tag.mime, 'document-format', 'image/jpeg');
    }, jobAttrs: (e) => _jobAttrs(e, paper, copies, color), data: jpeg);
    return a['job-id']!.first as int;
  }

  Future<String> jobState(int jobId) async {
    final (_, a) = await _request(0x09, (e) => e.integer('job-id', jobId));
    return jobStates[a['job-state']?.first] ?? 'unknown';
  }

  Future<String> printerState() async {
    final a = await attributes(['printer-state', 'printer-state-reasons']);
    final s = const {3: 'Ready', 4: 'Printing', 5: 'Stopped'}[a['printer-state']?.first] ?? 'Unknown';
    final reasons = (a['printer-state-reasons'] ?? []).where((r) => r != 'none').join(', ');
    return reasons.isEmpty ? s : '$s ($reasons)';
  }
}
