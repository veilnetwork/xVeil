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
      expect(() => NodeId(Uint8List(31)), throwsA(isA<ArgumentError>()));
      expect(() => NodeId(Uint8List(33)), throwsA(isA<ArgumentError>()));
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

    test('hex is two lowercase digits per byte, for every byte value', () {
      // Every stored key and every comparison of ids goes through this
      // string; the table form must spell each byte exactly as the per-byte
      // `toRadixString` form it replaced.
      for (var start = 0; start < 256; start += 32) {
        final bytes = Uint8List.fromList([
          for (var i = 0; i < 32; i++) start + i,
        ]);
        final expected = [
          for (final b in bytes) b.toRadixString(16).padLeft(2, '0'),
        ].join();
        final id = NodeId(bytes);
        expect(id.hex, expected);
        expect(NodeId.fromHex(id.hex), id);
      }
    });

    test('fromHex reads every byte with lower, upper and mixed case', () {
      for (var value = 0; value < 256; value++) {
        final lower = value.toRadixString(16).padLeft(2, '0');
        for (final pair in {
          lower,
          lower.toUpperCase(),
          '${lower[0].toUpperCase()}${lower[1]}',
          '${lower[0]}${lower[1].toUpperCase()}',
        }) {
          final parsed = NodeId.fromHex(List.filled(32, pair).join());
          expect(parsed.bytes, List.filled(32, value), reason: pair);
        }
      }
    });

    test('fromHex preserves legacy parsing for every ASCII pair', () {
      final zeros = List.filled(31, '00').join();
      for (var left = 0; left < 128; left++) {
        for (var right = 0; right < 128; right++) {
          final pair = String.fromCharCodes([left, right]);
          for (final input in ['$pair$zeros', '$zeros$pair']) {
            _expectLegacyHexParsing(input);
          }
        }
      }
    });

    test('fromHex preserves spaces, Unicode and malformed input behavior', () {
      final zeros = List.filled(31, '00').join();
      for (final pair in [
        '+f',
        '-a',
        '\tf',
        'f\t',
        '\nf',
        'f\r',
        '\u00a0a',
        'a\u2000',
        '\u2028f',
        'f\u2029',
        '\u3000a',
        '\u200bf',
        '\ud800a',
        '\udc00f',
        '\uff10a',
        '\u0660f',
        '😀',
      ]) {
        _expectLegacyHexParsing('$pair$zeros');
        _expectLegacyHexParsing('$zeros$pair');
      }
      for (final value in [
        '',
        '00',
        '0' * 63,
        '0' * 65,
        '0' * 66,
        '  ${'aB' * 32}  ',
        List.filled(32, ' a B ').join(),
      ]) {
        _expectLegacyHexParsing(value);
      }
      expect(NodeId.fromHex('$zeros-f').bytes.last, 241);
    });

    test('fromHex gives each result its own mutable bytes', () {
      final raw = 'aB' * 32;
      final first = NodeId.fromHex(raw);
      final second = NodeId.fromHex(raw);
      first.bytes[0] = 0;
      expect(second.bytes, List.filled(32, 0xab));
      expect(NodeId.fromHex(raw).bytes, List.filled(32, 0xab));
    });
  });

  test(
    'writer-key hex keeps the existing byte format without a node-id length limit',
    () {
      for (final length in [0, 1, 31, 32, 33, 1312]) {
        final bytes = Uint8List.fromList(List.generate(length, (i) => i % 256));
        final reference = bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(hexOfBytes(bytes), reference);
      }
      final bytes = Uint8List.fromList([0, 1, 15, 16, 127, 128, 254, 255]);
      expect(hexOfBytes(bytes), '00010f107f80feff');
      bytes[0] = 255;
      expect(
        hexOfBytes(bytes),
        'ff010f107f80feff',
        reason: 'encoding must not retain stale mutable key bytes',
      );
    },
  );

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

// The shipped substring/int.parse decoder is the compatibility oracle. Do not
// reuse the optimized nibble decoder here: noncanonical signs and whitespace
// are accepted by int.parse too, and Uint8List wraps a negative parsed value.
NodeId _legacyHex(String hex) {
  final clean = hex.replaceAll(' ', '');
  if (clean.length != 64) {
    throw ArgumentError('node id hex must be 64 chars, got ${clean.length}');
  }
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return NodeId(out);
}

void _expectLegacyHexParsing(String input) {
  NodeId? expected;
  Object? error;
  try {
    expected = _legacyHex(input);
  } catch (caught) {
    error = caught;
  }
  if (error != null) {
    expect(
      () => NodeId.fromHex(input),
      throwsA(
        predicate<Object>(
          (actual) =>
              actual.runtimeType == error.runtimeType &&
              actual.toString() == error.toString(),
        ),
      ),
    );
  } else {
    expect(NodeId.fromHex(input).bytes, expected!.bytes);
  }
}
