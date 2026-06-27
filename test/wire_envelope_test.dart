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

  test('fileMeta round-trips the filePost seq + send-time (convergence)', () {
    final raw = fileMetaEnvelope(
      transferId: 't1',
      name: 'photo.bin',
      size: 5000,
      count: 1,
      seq: 7,
      sentAtMs: 1782490000000,
    ).encode();
    final f = parseFileMeta(WireEnvelope.decode(raw).body);
    expect(f.transferId, 't1');
    expect(f.name, 'photo.bin');
    expect(f.seq, 7);
    expect(f.sentAtMs, 1782490000000);
    // An older sender omits both → null (the receiver allocates seq / receive ts).
    final legacy = parseFileMeta(
        fileMetaEnvelope(transferId: 't2', name: 'x', size: 1, count: 1).body);
    expect(legacy.seq, isNull);
    expect(legacy.sentAtMs, isNull);
  });

  test('fileQuery round-trips (probe body parses as a meta; carries v:2)', () {
    final raw = fileQueryEnvelope(
      transferId: 't9',
      name: 'doc.pdf',
      seq: 4,
      sentAtMs: 1782490000000,
    ).encode();
    final out = WireEnvelope.decode(raw);
    expect(out.kind, WireKind.fileQuery);
    final f = parseFileMeta(out.body); // a probe reuses the meta body shape
    expect(f.transferId, 't9');
    expect(f.name, 'doc.pdf');
    expect(f.seq, 4);
    expect(f.sentAtMs, 1782490000000);
    expect((jsonDecode(utf8.decode(raw)) as Map)['v'], 2);
  });

  test('a file chunk wire frame stays under the 6144 auth_deliver cap', () {
    // veil's anonymous authenticated send (the live path) drops any message
    // whose encoded size exceeds MAX_AUTH_DELIVER_MSG_BYTES = 6144 bytes — a
    // chunk is base64 + JSON-wrapped, so a too-large raw chunk silently kills
    // every file frame on the live path. The wire chunk size (4000) must encode
    // to comfortably under 6144 (leaving room for the AuthDeliver header/sig).
    const cap = 6144;
    final tid = 'a1b2c3d4-e5f6-7890-abcd-ef0123456789'; // realistic uuid length
    Uint8List frame(int raw) => fileChunkEnvelope(
          transferId: tid,
          index: 3,
          total: 99,
          data: Uint8List(raw),
        ).encode();
    expect(frame(4000).length, lessThan(cap - 400),
        reason: 'the 4000-byte wire chunk must fit the auth_deliver cap '
            'with margin for the AuthDeliver framing');
    // Document the regression: the old 6000-byte chunk overflowed the cap.
    expect(frame(6000).length, greaterThan(cap),
        reason: 'the old 6000-byte chunk exceeded the cap — every file frame '
            'was dropped on the live path');
  });

  test('fileNack round-trips missing indices; absent m means "all"', () {
    final some = parseFileNack(
        WireEnvelope.decode(fileNackEnvelope(transferId: 't9', missing: [1, 4, 7]).encode()).body);
    expect(some.transferId, 't9');
    expect(some.missing, [1, 4, 7]);
    // null missing → "send me everything".
    final all = parseFileNack(
        WireEnvelope.decode(fileNackEnvelope(transferId: 't9', missing: null).encode()).body);
    expect(all.missing, isNull);
  });

  test('a fileStream frame round-trips (meta-shaped, no count; carries v:2)', () {
    final raw = fileStreamEnvelope(
      transferId: 'big-1',
      name: 'movie.mp4',
      size: 50000000,
      seq: 8,
      sentAtMs: 1782490000000,
    ).encode();
    final out = WireEnvelope.decode(raw);
    expect(out.kind, WireKind.fileStream);
    final f = parseFileMeta(out.body); // reuses the meta body shape
    expect(f.transferId, 'big-1');
    expect(f.name, 'movie.mp4');
    expect(f.size, 50000000);
    expect(f.count, isNull, reason: 'a stream is not pre-chunked');
    expect(f.seq, 8);
    expect((jsonDecode(utf8.decode(raw)) as Map)['v'], 2,
        reason: 'large-file frame drops on un-upgraded builds (RULE WC)');
  });

  test('a reconnect frame round-trips its greeting (+ v:2 marker)', () {
    final raw = const WireEnvelope.reconnect('we were connected').encode();
    final out = WireEnvelope.decode(raw);
    expect(out.kind, WireKind.reconnect);
    expect(out.body, 'we were connected');
    expect((jsonDecode(utf8.decode(raw)) as Map)['v'], 2);
  });

  test('content-layer frames round-trip (manifest / pieceRequest / pieceChunk)',
      () {
    // contentManifest carries the manifest JSON verbatim.
    final cm = WireEnvelope.decode(
        contentManifestEnvelope('{"id":"abc","name":"x"}').encode());
    expect(cm.kind, WireKind.contentManifest);
    expect(cm.body, '{"id":"abc","name":"x"}');

    // pieceRequest: specific indices, and "all" (absent).
    final some = parsePieceRequest(WireEnvelope.decode(
            pieceRequestEnvelope(contentId: 'c1', indices: [2, 5]).encode())
        .body);
    expect(some.contentId, 'c1');
    expect(some.indices, [2, 5]);
    final all = parsePieceRequest(WireEnvelope.decode(
            pieceRequestEnvelope(contentId: 'c1', indices: null).encode())
        .body);
    expect(all.indices, isNull);

    // pieceChunk: (piece, chunk) coordinates + data.
    final pc = parsePieceChunk(WireEnvelope.decode(pieceChunkEnvelope(
      contentId: 'c1',
      pieceIndex: 3,
      chunkIndex: 7,
      chunkCount: 64,
      data: Uint8List.fromList([1, 2, 3, 4]),
    ).encode()).body);
    expect(pc.contentId, 'c1');
    expect(pc.pieceIndex, 3);
    expect(pc.chunkIndex, 7);
    expect(pc.chunkCount, 64);
    expect(pc.data, [1, 2, 3, 4]);
    // All three carry v:2 → un-upgraded builds drop them (RULE WC).
    for (final e in [
      contentManifestEnvelope('{}'),
      pieceRequestEnvelope(contentId: 'c', indices: null),
      pieceChunkEnvelope(
          contentId: 'c', pieceIndex: 0, chunkIndex: 0, chunkCount: 1, data: Uint8List(1)),
    ]) {
      expect((jsonDecode(utf8.decode(e.encode())) as Map)['v'], 2);
    }
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
