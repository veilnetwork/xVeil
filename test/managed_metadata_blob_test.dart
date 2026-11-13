import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';

class _LostCommit implements Exception {}

class _InterruptibleStore extends FakeKvLogStore {
  int? remaining;
  bool after = false;

  @override
  int commit(List<KvLogOp> ops) {
    final interrupt = remaining == 0;
    if (remaining != null) remaining = remaining! - 1;
    if (interrupt && !after) throw _LostCommit();
    final result = super.commit(ops);
    if (interrupt) throw _LostCommit();
    return result;
  }
}

void main() {
  Uint8List payload(int length, int seed) =>
      Uint8List.fromList(List.generate(length, (i) => (i + seed) % 251));

  test('large maintenance payload is independent of caller buffers', () {
    final store = _InterruptibleStore();
    final blob = ManagedMetadataBlob(store);
    final expected = payload(49155, 1);
    final input = Uint8List.fromList(expected);
    blob.write(input, initialize: true);
    input.fillRange(0, input.length, 0);
    expect(ManagedMetadataBlob(store).read(), expected);
    expect(() => blob.write(expected, initialize: true), throwsStateError);
  });

  test('every interruption exposes either old or complete new metadata', () {
    final before = payload(4097, 1);
    final next = payload(4099, 2);
    // Five chunks and the head; fail before and after each actual commit.
    for (final after in [false, true]) {
      for (var boundary = 0; boundary < 6; boundary++) {
        final store = _InterruptibleStore();
        final blob = ManagedMetadataBlob(store)
          ..write(before, initialize: true);
        store
          ..after = after
          ..remaining = boundary;
        expect(() => blob.write(next), throwsA(isA<_LostCommit>()));
        expect(
          ManagedMetadataBlob(store).read(),
          after && boundary == 5 ? next : before,
          reason: 'boundary=$boundary after=$after',
        );
        store.remaining = null;
        blob.write(next);
        expect(blob.read(), next);
      }
    }
  });

  test('interrupted unpublished initialization is explicit and retryable', () {
    final store = _InterruptibleStore()..remaining = 2;
    final blob = ManagedMetadataBlob(store);
    final value = payload(4096, 1);
    expect(
      () => blob.write(value, initialize: true),
      throwsA(isA<_LostCommit>()),
    );
    expect(blob.read, throwsStateError);
    expect(() => blob.write(value), throwsStateError);
    store.remaining = null;
    blob.write(value, initialize: true);
    expect(blob.read(), value);
  });

  test(
    'empty and maximum payloads remain bounded across repeated rewrites',
    () {
      final store = _InterruptibleStore();
      final blob = ManagedMetadataBlob(store);
      blob.write(Uint8List(0), initialize: true);
      expect(blob.read(), isEmpty);
      for (var i = 0; i < 12; i++) {
        final value = payload(ManagedMetadataBlob.maxBytes, i);
        blob.write(value);
        expect(blob.read(), value);
        expect(
          store.count(ManagedMetadataBlob.namespace),
          lessThanOrEqualTo(129),
        );
      }
      final previous = blob.read();
      expect(
        () => blob.write(Uint8List(ManagedMetadataBlob.maxBytes + 1)),
        throwsArgumentError,
      );
      expect(blob.read(), previous);
      blob.write(Uint8List(0));
      expect(blob.read(), isEmpty);
    },
  );

  test(
    'incomplete or mismatching published chunks refuse read and rewrite',
    () {
      for (final bad in [Uint8List(0), payload(1024, 99)]) {
        final store = _InterruptibleStore();
        final blob = ManagedMetadataBlob(store)
          ..write(payload(2048, 1), initialize: true);
        store.commit([AppendLogOp(ManagedMetadataBlob.namespace, 2, bad)]);
        expect(blob.read, throwsFormatException);
        expect(() => blob.write(payload(2048, 2)), throwsFormatException);
      }
      final store = _InterruptibleStore();
      final blob = ManagedMetadataBlob(store)
        ..write(payload(2048, 1), initialize: true);
      store.commit([DeleteLogOp(ManagedMetadataBlob.namespace, 2)]);
      expect(blob.read, throwsFormatException);
    },
  );

  test(
    'malformed or oversized head is refused without reading arbitrary IDs',
    () {
      for (final head in [
        Uint8List(0),
        Uint8List(38)..[0] = 2,
        Uint8List(38)
          ..[0] = 1
          ..[1] = 2,
        Uint8List(38)
          ..[0] = 1
          ..[2] = 255,
      ]) {
        final store = _InterruptibleStore();
        store.commit([AppendLogOp(ManagedMetadataBlob.namespace, 1, head)]);
        expect(ManagedMetadataBlob(store).read, throwsFormatException);
      }
    },
  );
}
