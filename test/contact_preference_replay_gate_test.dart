import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/device_sync.dart';

DeviceSyncEvent pref(int at, String name) => DeviceSyncEvent(
  kind: DeviceSyncKind.contactUp,
  key: 'peer',
  tsMs: at,
  payload: {'name': name},
);
void main() {
  test('late status replay cannot overwrite a newer preference slot', () async {
    final gate = DeviceSyncApplyGate(nowMs: () => 100);
    final old = pref(1, 'old'), newer = pref(2, 'new');
    String? value;
    void offer(DeviceSyncEvent e) => gate.offer(
      e,
      () => () async {
        value = e.payload['name'] as String;
      },
    );
    offer(old);
    await gate.settle();
    final captured = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    gate.offer(
      DeviceSyncEvent(
        kind: DeviceSyncKind.contactUp,
        key: 's:peer',
        tsMs: 1,
        payload: {'status': 'accepted'},
      ),
      () => () async {
        final held = old;
        captured.complete();
        await release.future;
        await gate.settleSlot(held);
        offer(held);
      },
    );
    await captured.future;
    offer(newer);
    // The newer preference can commit while status replay is still delayed.
    await pumpEventQueue();
    expect(value, 'new');
    release.complete();
    await gate.settle();
    expect(value, 'new');
  });
  test('deferred unknown contact can re-offer after materialization', () async {
    final gate = DeviceSyncApplyGate(nowMs: () => 100), event = pref(1, 'name');
    var exists = false, writes = 0;
    void offer() => gate.offer(
      event,
      () => () async {
        if (!exists) throw const DeviceSyncApplyDeferred();
        writes++;
      },
    );
    offer();
    await gate.settleSlot(event);
    expect(writes, 0);
    expect(gate.failedApplies, 0);
    exists = true;
    offer();
    await gate.settleSlot(event);
    expect(writes, 1);
  });
  test(
    'joining a preference slot does not wait for another blocked slot',
    () async {
      final gate = DeviceSyncApplyGate(nowMs: () => 100),
          release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final event = pref(1, 'ready');
      var committed = false;
      gate.offer(
        DeviceSyncEvent(
          kind: DeviceSyncKind.contactUp,
          key: 's:peer',
          tsMs: 1,
          payload: {},
        ),
        () =>
            () => release.future,
      );
      gate.offer(
        event,
        () => () async {
          committed = true;
        },
      );
      await gate.settleSlot(event);
      expect(committed, true);
      expect(release.isCompleted, false);
      release.complete();
      await gate.close();
    },
  );
}
