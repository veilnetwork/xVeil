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

  // Event-log 3c wire additions.

  test('edit and del carry the event seq (gap-fill / convergence)', () {
    final edit = WireEnvelope.decode(
        const WireEnvelope.edit('m1', 'new body', seq: 7).encode());
    expect(edit.kind, WireKind.edit);
    expect(edit.id, 'm1');
    expect(edit.seq, 7);
    final del =
        WireEnvelope.decode(const WireEnvelope.del('m2', seq: 9).encode());
    expect(del.kind, WireKind.del);
    expect(del.seq, 9);
  });

  test('a sync beacon round-trips its body (and carries the v:2 marker)', () {
    final raw = const WireEnvelope.sync('{"hw":{"a":3}}').encode();
    final out = WireEnvelope.decode(raw);
    expect(out.kind, WireKind.sync);
    expect(out.body, '{"hw":{"a":3}}');
    // v:2 is present on the wire so an un-upgraded decoder drops it (RULE WC).
    expect((jsonDecode(utf8.decode(raw)) as Map)['v'], 2);
  });

  test('a voidSeq frame round-trips its seq with no id/body', () {
    final out = WireEnvelope.decode(const WireEnvelope.voidSeq(5).encode());
    expect(out.kind, WireKind.voidSeq);
    expect(out.seq, 5);
    expect(out.id, isNull);
    expect(out.body, isEmpty);
  });

  test('RULE WC: a structured v:2 frame whose kind this build does not know '
      'decodes to the DROP sentinel — never rendered as chat text', () {
    // A future build's kind (out of this build's range) carried as a v:2 frame.
    final future = Uint8List.fromList(
        utf8.encode('{"t":99,"b":"{\\"hw\\":{}}","v":2}'));
    final out = WireEnvelope.decode(future);
    expect(out.kind, WireKind.unknown,
        reason: 'a v:2 frame from a newer build must be dropped, not shown');
    expect(out.kind, isNot(WireKind.message));
  });

  test('a NON-v2 out-of-range frame still falls back to a plain message '
      '(legacy compatibility unchanged)', () {
    final legacy = Uint8List.fromList(utf8.encode('{"t":99,"b":"hi"}'));
    expect(WireEnvelope.decode(legacy).kind, WireKind.message);
  });

  test('the unknown sentinel index is never decoded to a real kind', () {
    // Even WITHOUT a v marker, the unknown sentinel's own index must not map to
    // a usable kind — it falls back to a plain message (it is decode-only).
    final raw =
        Uint8List.fromList(utf8.encode('{"t":${WireKind.unknown.index},"b":"x"}'));
    expect(WireEnvelope.decode(raw).kind, WireKind.message);
  });
}
