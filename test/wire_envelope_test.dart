import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/wire_envelope.dart';

void main() {
  test('each kind round-trips through encode/decode', () {
    for (final env in [
      const WireEnvelope.request('hi, can we connect?'),
      const WireEnvelope.accept(),
      const WireEnvelope.message('hello'),
    ]) {
      final out = WireEnvelope.decode(env.encode());
      expect(out.kind, env.kind);
      expect(out.body, env.body);
    }
  });

  test('a non-envelope payload decodes as a plain message', () {
    final raw = Uint8List.fromList(utf8.encode('legacy plain text'));
    final out = WireEnvelope.decode(raw);
    expect(out.kind, WireKind.message);
    expect(out.body, 'legacy plain text');
  });

  test('malformed bytes do not throw', () {
    final out = WireEnvelope.decode(Uint8List.fromList([0xff, 0x00, 0x10]));
    expect(out.kind, WireKind.message);
  });
}
