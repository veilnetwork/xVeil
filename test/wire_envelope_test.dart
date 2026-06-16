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

  test('the id field round-trips (load-bearing for dedup + no-resurrection)', () {
    expect(WireEnvelope.decode(const WireEnvelope.message('hi', id: 'u-123').encode()).id,
        'u-123');
    expect(WireEnvelope.decode(const WireEnvelope.message('hi').encode()).id, isNull);
    // request carries an id too (the greeting-dedup fix relies on this).
    expect(WireEnvelope.decode(const WireEnvelope.request('hey', id: 'r-9').encode()).id,
        'r-9');
  });

  test('edit and del round-trip with their id', () {
    final edit = WireEnvelope.decode(const WireEnvelope.edit('m1', 'new body').encode());
    expect(edit.kind, WireKind.edit);
    expect(edit.id, 'm1');
    expect(edit.body, 'new body');
    final del = WireEnvelope.decode(const WireEnvelope.del('m2').encode());
    expect(del.kind, WireKind.del);
    expect(del.id, 'm2');
  });

  test('a valid-JSON frame with an out-of-range/wrong-typed kind falls back to '
      'a plain message (no crash, never mis-mapped to a typed kind)', () {
    for (final body in [
      '{"t":999,"b":"x"}', // kind index out of range
      '{"t":-1,"b":"x"}', // negative kind
      '{"t":"nope","b":"x"}', // kind wrong type
      '{"b":"missing the kind"}', // no t
      '{"t":0}', // no b
    ]) {
      final out = WireEnvelope.decode(Uint8List.fromList(utf8.encode(body)));
      expect(out.kind, WireKind.message,
          reason: 'hostile frame `$body` must not map to a typed kind');
    }
  });
}
