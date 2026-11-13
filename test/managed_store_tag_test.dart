import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_store_tag.dart';

void main() {
  final id = ManagedIdentityId('1' * 32);
  test('only the expected owned role is accepted', () {
    for (final role in ManagedStoreRole.values) {
      final store = FakeKvLogStore();
      final tag = ManagedStoreTag(
        identity: id,
        role: role,
        generation: role == ManagedStoreRole.content ? 'a' * 64 : null,
      );
      expect(
        () => ManagedStoreTag.read(store, identity: id, role: role),
        throwsStateError,
      );
      store.commit([tag.putOp()]);
      final read = ManagedStoreTag.read(store, identity: id, role: role);
      expect(read.encode(), tag.encode());
      expect(
        () => ManagedStoreTag.read(
          store,
          identity: ManagedIdentityId('2' * 32),
          role: role,
        ),
        throwsStateError,
      );
      for (final other in ManagedStoreRole.values.where((r) => r != role)) {
        expect(
          () => ManagedStoreTag.read(store, identity: id, role: other),
          throwsStateError,
        );
      }
    }
  });
  test('unknown format, partial markers and extra bytes are refused', () {
    for (final role in ManagedStoreRole.values) {
      final tag = ManagedStoreTag(
        identity: id,
        role: role,
        generation: role == ManagedStoreRole.content ? 'a' * 64 : null,
      );
      final encoded = tag.encode();
      for (var n = 0; n < encoded.length; n++) {
        expect(
          () => ManagedStoreTag.decode(encoded.sublist(0, n)),
          throwsFormatException,
        );
      }
      expect(
        () => ManagedStoreTag.decode(Uint8List.fromList([...encoded, 0])),
        throwsFormatException,
      );
      for (final position in [0, 4, 5]) {
        final bad = Uint8List.fromList(encoded)..[position] = 255;
        expect(() => ManagedStoreTag.decode(bad), throwsFormatException);
      }
    }
  });
  test('content alone requires exactly one generation marker', () {
    expect(
      () => ManagedStoreTag(identity: id, role: ManagedStoreRole.content),
      throwsArgumentError,
    );
    expect(
      () => ManagedStoreTag(
        identity: id,
        role: ManagedStoreRole.content,
        generation: 'PRIVATE_INVALID_MARKER',
      ),
      throwsArgumentError,
    );
    for (final role in [
      ManagedStoreRole.keybox,
      ManagedStoreRole.maintenance,
    ]) {
      expect(
        () => ManagedStoreTag(identity: id, role: role, generation: 'a' * 64),
        throwsArgumentError,
      );
    }
  });
}
