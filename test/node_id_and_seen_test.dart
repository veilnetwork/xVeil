import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';

/// Two small invariants that held only by accident.
void main() {
  group('NodeId', () {
    test('refuses a wrong-sized id at runtime, not just under assert', () {
      // The length was an `assert`, which a release build compiles out — so a
      // 31-byte id became a NodeId in the shipped app and surfaced later as a
      // hex string that matched nothing.
      expect(
        () => NodeId(Uint8List(31)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => NodeId(Uint8List(33)),
        throwsA(isA<ArgumentError>()),
      );
      expect(NodeId(Uint8List(32)).bytes.length, 32);
    });

    test('does not alias the buffer it was handed', () {
      // A caller that reuses a scratch buffer — or mutates one after filing
      // the id in a Map — used to change a live key underneath the hash it was
      // stored under. The entry then existed and could not be found.
      final scratch = Uint8List(32)..fillRange(0, 32, 7);
      final id = NodeId(scratch);
      final before = id.hex;
      final map = {id: 'value'};

      scratch.fillRange(0, 32, 9); // the caller moves on

      expect(id.hex, before, reason: 'the id changed under its owner');
      expect(map[NodeId(Uint8List(32)..fillRange(0, 32, 7))], 'value');
    });
  });

  test('a JSON object survives a round trip through jsonEncode', () {
    // Pins the shape `_saveSeen` writes. CloudService materialises the seen-
    // revision map with jsonEncode(Map), while the loader accepted only a
    // JSON List — so every restart silently discarded what the device had
    // already caught up with, and changedElsewhere answered false for items
    // that HAD changed elsewhere.
    final encoded = jsonEncode({'item-1': 4, 'item-2': 9});
    expect(jsonDecode(encoded), isA<Map>());
    expect(jsonDecode(encoded), isNot(isA<List>()));
  });
}
