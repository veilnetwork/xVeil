import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_reclaim_budget.dart';

void main() {
  test(
    'budget codec preserves bounded counts including signed-integer edge',
    () {
      for (final value in [0, 17, 0x7fffffffffffffff]) {
        final encoded = ManagedReclaimBudget(
          contentBytes: value,
          contentOwned: value,
          maintenanceBytes: value,
        ).encode();
        expect(encoded.length, 32);
        final read = ManagedReclaimBudget.decode(encoded);
        expect(
          [read.contentBytes, read.contentOwned, read.maintenanceBytes],
          [value, value, value],
        );
      }
    },
  );
  test(
    'malformed version, length and unsigned overflow never become defaults',
    () {
      final valid = ManagedReclaimBudget().encode();
      for (final invalid in [
        valid.sublist(1),
        Uint8List(33),
        Uint8List.fromList(valid)..[4] = 2,
        Uint8List.fromList(valid)..[8] = 0x80,
        Uint8List.fromList(valid)..[16] = 0x80,
        Uint8List.fromList(valid)..[24] = 0x80,
      ]) {
        expect(
          () => ManagedReclaimBudget.decode(invalid),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'fresh floor and persisted growth hysteresis avoid continuous repacking',
    () {
      final fresh = ManagedReclaimBudget();
      expect(
        fresh.contentDue(ManagedReclaimBudget.contentFloor - 1, 10),
        isFalse,
      );
      expect(fresh.contentDue(ManagedReclaimBudget.contentFloor, null), isTrue);
      final large = ManagedReclaimBudget(
        contentBytes: 256 << 20,
        contentOwned: 1000,
      );
      expect(large.contentDue((512 << 20) - 1, 1000), isFalse);
      expect(large.contentDue(512 << 20, 1000), isTrue);
      final edge = ManagedReclaimBudget(contentBytes: 0x7fffffffffffffff);
      expect(edge.contentDue(0x7fffffffffffffff, null), isFalse);
    },
  );
  test(
    'substantial deletion triggers without new file growth but respects floor',
    () {
      final budget = ManagedReclaimBudget(
        contentBytes: 256 << 20,
        contentOwned: 1024,
      );
      expect(budget.contentDue(256 << 20, 768), isFalse);
      expect(budget.contentDue(256 << 20, 767), isTrue);
      expect(budget.contentDue(1024, 0), isFalse);
      expect(budget.contentDue(256 << 20, null), isFalse);
      expect(() => budget.contentDue(-1, 2), throwsArgumentError);
      expect(() => budget.contentDue(1, -1), throwsArgumentError);
    },
  );
  test('maintenance has independent growth budget and explicit force', () {
    final budget = ManagedReclaimBudget(maintenanceBytes: 2 << 20);
    expect(budget.maintenanceDue((10 << 20) - 1), isFalse);
    expect(budget.maintenanceDue(10 << 20), isTrue);
    expect(budget.maintenanceDue(1, force: true), isTrue);
    expect(budget.contentDue(1, null, force: true), isTrue);
  });
  test('missing is fresh; unreadable authenticated hints are preserved', () {
    final store = FakeKvLogStore();
    expect(ManagedReclaimBudget.read(store).contentBytes, 0);
    ManagedReclaimBudget(contentBytes: 123).write(store);
    expect(ManagedReclaimBudget.read(store).contentBytes, 123);
    final key = store.kvKeys(Ns.settings).single;
    final corrupt = store.get(Ns.settings, key)!..[0] = 0;
    store.commit([PutOp(Ns.settings, key, corrupt)]);
    expect(() => ManagedReclaimBudget.read(store), throwsFormatException);
    expect(store.get(Ns.settings, key), corrupt);
    store.close();
  });
}
