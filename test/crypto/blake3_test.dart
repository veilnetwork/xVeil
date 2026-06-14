import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/transport/veil_addressing.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('BLAKE3 of empty input matches the official vector', () {
    expect(
      _hex(blake3Hash(Uint8List(0))),
      'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
    );
  });

  test('BLAKE3 of "abc" matches the official vector', () {
    expect(
      _hex(blake3Hash(Uint8List.fromList('abc'.codeUnits))),
      '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85',
    );
  });

  group('deriveAppId matches the veil-app reference vectors', () {
    final node = NodeId(Uint8List.fromList(List.filled(32, 0x01)));

    test('veil.chat / main', () {
      expect(
        _hex(deriveAppId(node, 'veil.chat', 'main')),
        '891db41cfa68a6fea8a10e6b02dd12e97a0ff9beb2935217be9feb97c5df2b49',
      );
    });

    test('xveil / inbox (the chat endpoint)', () {
      expect(
        _hex(deriveAppId(node, 'xveil', 'inbox')),
        'deaf3395a8fe371818be6dc9795fb27b5ab6ee86bfddc5d56fe03303dd9fecc9',
      );
      expect(_hex(chatAppIdFor(node)),
          'deaf3395a8fe371818be6dc9795fb27b5ab6ee86bfddc5d56fe03303dd9fecc9');
    });
  });
}
