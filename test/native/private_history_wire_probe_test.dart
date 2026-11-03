import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import '../support/private_history_wire_probe.dart';

void main() {
  test(
    'private history observer preserves the app listener and omits payload data',
    () async {
      final root = await Directory.systemTemp.createTemp('history-probe-');
      addTearDown(() => root.delete(recursive: true));
      final frames = StreamController<InboundMessage>.broadcast();
      final received = <InboundMessage>[];
      final errors = <Object>[];
      final app = frames.stream.listen(received.add, onError: errors.add);
      final file = File('${root.path}/wire.jsonl');
      final probe = PrivateHistoryWireProbe(frames.stream, file, maxRecords: 1);
      final sender = NodeId(Uint8List(32)..fillRange(0, 32, 19));
      InboundMessage packet(String body) => InboundMessage(
        src: sender,
        payload: WireEnvelope.deviceHistory(body).encode(),
        provenance: SenderProvenance.signed,
      );
      final query = packet(
        jsonEncode({
          'id': 'a' * 32,
          'q': {
            'op': 'page',
            'private': 'must-not-be-recorded',
            'prefix': {
              'count': 32,
              'hash': 'private-content-digest',
              'position': [1000, 'private-message-id'],
            },
            'prefixFallbacks': [
              {
                'count': 16,
                'hash': 'private-content-digest',
                'position': [500, 'private-message-id'],
              },
            ],
          },
        }),
      );
      final part = packet(
        jsonEncode({
          'id': 'a' * 32,
          'i': 0,
          'n': 1,
          'b': base64Encode(utf8.encode('secret-content')),
        }),
      );
      frames.add(query);
      frames.add(part);
      frames.add(packet('not JSON'));
      final transportError = StateError('private transport failure');
      frames.addError(transportError);
      await Future<void>(() {});
      await probe.close();
      frames.add(query);
      await Future<void>(() {});
      expect(received, [query, part, isA<InboundMessage>(), query]);
      expect(errors, [transportError]);
      final text = await file.readAsString();
      final rows = text
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(rows.map((row) => row['kind']), ['open', 'query', 'close']);
      expect(rows[1]['request'], 'a' * 32);
      expect(rows[1]['op'], 'page');
      expect(rows[1]['prefixRows'], 32);
      expect(rows[1]['prefixCandidates'], 2);
      expect(rows.last['recorded'], 1);
      expect(rows.last['dropped'], 1);
      expect(text, isNot(contains('must-not-be-recorded')));
      expect(text, isNot(contains('secret-content')));
      expect(text, isNot(contains('private transport failure')));
      expect(text, isNot(contains('private-content-digest')));
      expect(text, isNot(contains('private-message-id')));
      expect(text, isNot(contains(sender.hex)));
      await app.cancel();
      await frames.close();
    },
  );
}
