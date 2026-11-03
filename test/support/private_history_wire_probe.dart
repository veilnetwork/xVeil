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
      _sink.writeln(
        jsonEncode({
          'kind': op == null ? 'part' : 'query',
          'atUs': _now(),
          'request': body['id'],
          'bytes': message.payload.length,
          'provenance': message.provenance.name,
          'op': ?op,
          if (op == null && body['i'] is int) 'index': body['i'],
          if (op == null && body['n'] is int) 'parts': body['n'],
        }),
      );
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
