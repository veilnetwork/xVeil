import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/chat.dart';

/// A contact id is 32 bytes; the index stores its 64-character hex.
NodeId _contact(int n) =>
    NodeId(Uint8List.fromList(List.generate(32, (i) => (n + i) & 0xFF)));

void main() {
  group('the contacts index past one settings value', () {
    late FakeKvLogStore store;
    late HiddenVolumeStorage storage;

    setUp(() async {
      store = FakeKvLogStore();
      storage = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : store,
      );
      await storage.open(password: 'pw', createIfMissing: true);
    });

    /// The thirty-first contact must be storable, and every one before it must
    /// still be listed.
    ///
    /// The index was ONE settings value, and a container caps one value at
    /// 2048 bytes. An id costs 67 of them inside a JSON list, so thirty ids
    /// encode to 2011 bytes and thirty-one to 2078 — past the cap. The index
    /// and the contact record travel in one transaction, so the refusal took
    /// the contact with it: a container stopped accepting new contacts at
    /// thirty, and the person was told nothing useful about why (report27
    /// X25).
    test('a container takes far more contacts than one value holds', () async {
      const count = 80;
      for (var n = 0; n < count; n += 1) {
        await storage.upsertContact(
          Contact(nodeId: _contact(n), name: 'contact $n'),
        );
      }

      final listed = await storage.loadConversations();
      expect(
        listed.length,
        count,
        reason:
            'the index holds ${listed.length} of $count contacts — everything '
            'past the point where it outgrew one settings value is missing, '
            'and so is the contact record that shared the transaction',
      );
      // And every one of them, not just the count.
      final hexes = listed.map((c) => c.peer.nodeId.hex).toSet();
      for (var n = 0; n < count; n += 1) {
        expect(
          hexes,
          contains(_contact(n).hex),
          reason: 'contact $n is not in the index',
        );
      }
    });

    /// Removing contacts must shrink the index rather than leave shards that
    /// still look authoritative.
    test('a shrinking index does not keep reading its old shards', () async {
      for (var n = 0; n < 60; n += 1) {
        await storage.upsertContact(Contact(nodeId: _contact(n)));
      }
      expect((await storage.loadConversations()).length, 60, reason: 'premise');

      for (var n = 0; n < 50; n += 1) {
        await storage.removeConversation(_contact(n));
      }

      final listed = await storage.loadConversations();
      expect(
        listed.map((c) => c.peer.nodeId.hex).toSet(),
        {for (var n = 50; n < 60; n += 1) _contact(n).hex},
        reason:
            'the index still lists removed contacts — a shard the shrunken '
            'index no longer writes was left behind and is still read',
      );
    });
  });
}
