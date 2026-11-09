import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';

/// An additional listener on the SDK's existing broadcast stream. Stand-only
/// private evidence: opaque request IDs never enter the application reports.
class PrivateHistoryWireProbe {
  PrivateHistoryWireProbe(
    Stream<InboundMessage> input,
    File file, {
    this.maxRecords = 2048,
    this.retainRecords = false,
  }) : _sink = file.openWrite(mode: FileMode.append) {
    _sink.writeln(jsonEncode({'kind': 'open', 'atUs': _now()}));
    _subscription = input.listen(
      _record,
      // The application's subscription owns transport failures. A passive
      // second subscription must not surface another unhandled stream error
      // or retain its potentially identifying text.
      onError: (Object error) {},
    );
  }

  final int maxRecords;
  final bool retainRecords;
  final _records = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> get snapshot => List.unmodifiable(_records);
  final IOSink _sink;
  late final StreamSubscription<InboundMessage> _subscription;
  int _recorded = 0, _dropped = 0;
  Future<void>? _closing;
  static int _now() => DateTime.now().microsecondsSinceEpoch;

  void _record(InboundMessage message) {
    if (message.payload.length > 6144) return;
    try {
      final envelope = WireEnvelope.decode(message.payload);
      if (envelope.kind != WireKind.deviceHistory) return;
      final body = jsonDecode(envelope.body);
      if (body is! Map ||
          body['id'] is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(body['id'] as String)) {
        return;
      }
      if (_recorded >= maxRecords) {
        _dropped++;
        return;
      }
      final query = body['q'];
      final op = query is Map ? query['op'] : null;
      if (op != null && !const ['list', 'page', 'record'].contains(op)) return;
      final prefix = query is Map ? query['prefix'] : null;
      final fallbacks = query is Map ? query['prefixFallbacks'] : null;
      final requestedRows = query is Map ? query['rows'] : null;
      final row = <String, dynamic>{
        'kind': op == null ? 'part' : 'query',
        'atUs': _now(),
        'request': body['id'],
        'bytes': message.payload.length,
        'provenance': message.provenance.name,
        'op': ?op,
        if (op == 'page' &&
            requestedRows is int &&
            requestedRows > 0 &&
            requestedRows <= 256)
          'requestedRows': requestedRows,
        if (op == 'page' && prefix is Map && prefix['count'] is int) ...{
          'prefixRows': prefix['count'],
          'prefixCandidates': 1 + (fallbacks is List ? fallbacks.length : 0),
        },
        if (op == null && body['i'] is int) 'index': body['i'],
        if (op == null && body['n'] is int) 'parts': body['n'],
      };
      if (retainRecords) {
        // Synthetic multi-source fixtures use this private in-memory view to
        // bind a reply to its actual physical sender. Disk logs stay minimal.
        _records.add(
          Map.unmodifiable({
            ...row,
            'fromDevice': (message.srcDevice ?? message.src).hex,
            'authenticated': message.provenance.isAuthenticated,
          }),
        );
      }
      _sink.writeln(jsonEncode(row));
      _recorded++;
    } on FormatException {
      // A passive observer does not turn malformed application input into a
      // new stream error, and never retains its text or payload.
    }
  }

  Future<void> close() => _closing ??= () async {
    await _subscription.cancel();
    _sink.writeln(
      jsonEncode({
        'kind': 'close',
        'atUs': _now(),
        'recorded': _recorded,
        'dropped': _dropped,
      }),
    );
    await _sink.close();
  }();
}
