import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/veil_mailbox_network.dart';

/// Byte-exact tests for the offline-mailbox network wire codecs
/// ([encodeMailboxPut] / [decodeMailboxFetchResp]) — they must match the Rust
/// `veil-proto` `MailboxPutPayload` / `MailboxFetchRespPayload` layouts exactly,
/// so a Dart-side regression can't silently corrupt deposits or drains.
void main() {
  group('encodeMailboxPut', () {
    test('produces the exact MailboxPutPayload layout', () {
      final receiver = Uint8List.fromList(List.filled(32, 0x0B));
      final content = Uint8List.fromList(List.filled(32, 0x42));
      final blob = Uint8List.fromList([1, 2, 3, 4, 5]);
      final wire = encodeMailboxPut(
          receiverId: receiver, contentId: content, blob: blob);

      // receiver(32) content(32) sender(32) blob_len(4) blob push(2) cap(2) wake(2)
      expect(wire.length, 32 + 32 + 32 + 4 + blob.length + 2 + 2 + 2);
      expect(wire.sublist(0, 32), receiver);
      expect(wire.sublist(32, 64), content);
      // sender_id is ZERO (anonymity — real id sealed in the blob).
      expect(wire.sublist(64, 96), Uint8List(32));
      final blobLen =
          ByteData.sublistView(wire, 96, 100).getUint32(0, Endian.big);
      expect(blobLen, blob.length);
      expect(wire.sublist(100, 100 + blob.length), blob);
      // The three trailing optional-field length prefixes are all 0 (absent).
      expect(wire.sublist(100 + blob.length), Uint8List(6));
    });

    test('handles an empty blob', () {
      final wire = encodeMailboxPut(
        receiverId: Uint8List(32),
        contentId: Uint8List(32),
        blob: Uint8List(0),
      );
      expect(wire.length, 32 + 32 + 32 + 4 + 0 + 6);
      expect(ByteData.sublistView(wire, 96, 100).getUint32(0, Endian.big), 0);
    });
  });

  group('decodeMailboxFetchResp', () {
    test('decodes an empty response (count=0)', () {
      final wire = _fetchResp([]);
      expect(decodeMailboxFetchResp(wire), isEmpty);
    });

    test('round-trips a single blob', () {
      final sender = Uint8List.fromList(List.filled(32, 0xAA));
      final content = Uint8List.fromList(List.filled(32, 0xC1));
      final blob = Uint8List.fromList([9, 8, 7]);
      final got = decodeMailboxFetchResp(_fetchResp([
        _entry(sender: sender, content: content, depositedAt: 1700, blob: blob),
      ]));
      expect(got.length, 1);
      expect(got[0].senderId.bytes, sender);
      expect(got[0].contentId, content);
      expect(got[0].blob, blob);
    });

    test('decodes multiple blobs in order', () {
      final got = decodeMailboxFetchResp(_fetchResp([
        _entry(
            sender: Uint8List(32),
            content: Uint8List.fromList(List.filled(32, 1)),
            depositedAt: 1,
            blob: Uint8List.fromList([1])),
        _entry(
            sender: Uint8List.fromList(List.filled(32, 2)),
            content: Uint8List.fromList(List.filled(32, 2)),
            depositedAt: 2,
            blob: Uint8List.fromList([2, 2])),
      ]));
      expect(got.length, 2);
      expect(got[0].blob, [1]);
      expect(got[1].blob, [2, 2]);
      expect(got[1].senderId.bytes, Uint8List.fromList(List.filled(32, 2)));
    });

    test('rejects a buffer too short for the count prefix', () {
      expect(() => decodeMailboxFetchResp(Uint8List(1)),
          throwsA(isA<FormatException>()));
    });

    test('rejects a truncated entry header', () {
      // count=1 but no entry bytes follow.
      final wire = Uint8List.fromList([0, 1]);
      expect(() => decodeMailboxFetchResp(wire),
          throwsA(isA<FormatException>()));
    });

    test('rejects a blob that overruns the buffer', () {
      final entry = _entry(
          sender: Uint8List(32),
          content: Uint8List(32),
          depositedAt: 0,
          blob: Uint8List.fromList([1, 2, 3]));
      // Drop the last blob byte so blob_len(3) overruns the actual bytes.
      final wire = _fetchResp([entry]);
      expect(() => decodeMailboxFetchResp(wire.sublist(0, wire.length - 1)),
          throwsA(isA<FormatException>()));
    });
  });
}

/// Build a `MailboxFetchRespPayload` wire buffer: count(u16 BE) + entries.
Uint8List _fetchResp(List<Uint8List> entries) {
  final b = BytesBuilder();
  final count = ByteData(2)..setUint16(0, entries.length, Endian.big);
  b.add(count.buffer.asUint8List());
  for (final e in entries) {
    b.add(e);
  }
  return b.toBytes();
}

/// One `MailboxBlobWire` entry: sender(32) content(32) deposited_at(u64 BE)
/// blob_len(u32 BE) blob.
Uint8List _entry({
  required Uint8List sender,
  required Uint8List content,
  required int depositedAt,
  required Uint8List blob,
}) {
  final b = BytesBuilder();
  b.add(sender);
  b.add(content);
  final ts = ByteData(8)..setUint64(0, depositedAt, Endian.big);
  b.add(ts.buffer.asUint8List());
  final len = ByteData(4)..setUint32(0, blob.length, Endian.big);
  b.add(len.buffer.asUint8List());
  b.add(blob);
  return b.toBytes();
}
