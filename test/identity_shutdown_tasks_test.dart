import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/async_tasks.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

void main() {
  test(
    'closing task scope joins an admitted write and refuses a new one',
    () async {
      final tasks = AsyncTasks();
      final release = Completer<void>();
      final writes = <String>[];
      final admitted = tasks.run(() async {
        await release.future;
        writes.add('old identity');
      });
      var closed = false;
      final closing = tasks.close().then((_) => closed = true);
      await tasks.run(() async => writes.add('after close'));
      expect(closed, isFalse);
      expect(writes, isEmpty);
      release.complete();
      await admitted;
      await closing;
      expect(writes, ['old identity']);
      await tasks.close();
    },
  );

  test('task error reaches the original caller and a waiting closer', () async {
    final tasks = AsyncTasks();
    final release = Completer<void>();
    final task = tasks.run(() async {
      await release.future;
      throw StateError('injected write failure');
    });
    final originalError = expectLater(task, throwsStateError);
    final closingError = expectLater(tasks.close(), throwsStateError);
    release.complete();
    await Future.wait([originalError, closingError]);
  });

  test('awaited task retains its result and refuses a closed owner', () async {
    final tasks = AsyncTasks();
    expect(await tasks.runRequired(() async => 42), 42);
    await tasks.close();
    var ran = false;
    await expectLater(
      tasks.runRequired(() async {
        ran = true;
        return 43;
      }),
      throwsStateError,
    );
    expect(ran, isFalse);
  });

  test(
    'session shutdown joins a provider already closing before storage closes',
    () async {
      final backing = FakeHvContainer();
      final storage = backing.storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      final messaging = MessagingService(LoopbackTransport(), storage);
      final tasks = AsyncTasks();
      final release = Completer<void>();
      final writing = tasks.run(() async {
        await release.future;
        await storage.putSetting('fixture', 'committed before close');
      });
      final closeProvider = messaging.registerShutdownTask(tasks.close);
      final providerClosing = closeProvider();
      var sessionClosed = false;
      final closing = messaging.dispose().then((_) => sessionClosed = true);
      await Future<void>.delayed(Duration.zero);
      expect(sessionClosed, isFalse);
      release.complete();
      await writing;
      await providerClosing;
      await closing;
      await storage.close();
      final reopened = backing.storage();
      await reopened.open(password: 'fixture', createIfMissing: false);
      expect(await reopened.getSetting('fixture'), 'committed before close');
      await reopened.close();
    },
  );

  test(
    'mirror permission read cannot resume under replacement group bindings',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      addTearDown(storage.close);
      final messaging = MessagingService(LoopbackTransport(), storage);
      addTearDown(messaging.dispose);
      messaging.groupBindingsOwner = Object();
      final entered = Completer<void>(), release = Completer<void>();
      messaging.isOwnDevice = (_) async {
        entered.complete();
        await release.future;
        return false;
      };
      final peer = NodeId(Uint8List.fromList(List.filled(32, 2)));
      final applying = messaging.applyMirroredMessage(
        peer: peer,
        msgId: 'fixture',
        direction: MessageDirection.outgoing,
        body: 'old binding',
        tsMs: 1000,
      );
      await entered.future;
      messaging.groupBindingsOwner = Object();
      release.complete();
      expect(await applying, isFalse);
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );

  test('cleanup is idempotent across provider and session shutdown', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'fixture', createIfMissing: true);
    addTearDown(storage.close);
    final messaging = MessagingService(LoopbackTransport(), storage);
    var closed = 0;
    final release = Completer<void>();
    final closeProvider = messaging.registerShutdownTask(() async {
      closed++;
      await release.future;
    });
    final a = closeProvider(), b = closeProvider();
    final closing = messaging.dispose();
    expect(closed, 1);
    release.complete();
    await Future.wait([a, b, closing]);
    expect(closed, 1);
    expect(() => messaging.registerShutdownTask(() async {}), throwsStateError);
  });

  test(
    'failed cleanup does not skip other cleanup or closing message streams',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      addTearDown(storage.close);
      final messaging = MessagingService(LoopbackTransport(), storage);
      var otherClosed = false;
      messaging.registerShutdownTask(
        () async => throw StateError('injected cleanup failure'),
      );
      messaging.registerShutdownTask(() async {
        otherClosed = true;
      });
      await expectLater(messaging.dispose(), throwsStateError);
      expect(otherClosed, isTrue);
      await messaging.changes
          .listen((_) {})
          .asFuture<void>()
          .timeout(const Duration(seconds: 1));
    },
  );

  test(
    'closed apply gate cancels queued plans and joins an active write',
    () async {
      final gate = DeviceSyncApplyGate(nowMs: () => 2000);
      final entered = Completer<void>(), release = Completer<void>();
      final writes = <int>[];
      DeviceSyncEvent event(int v) => DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'fixture',
        tsMs: v,
        payload: {'v': '$v'},
      );
      expect(
        gate.offer(
          event(1000),
          () => () async {
            entered.complete();
            await release.future;
            writes.add(1000);
          },
        ),
        isTrue,
      );
      await entered.future;
      expect(
        gate.offer(
          event(1001),
          () => () async {
            writes.add(1001);
          },
        ),
        isTrue,
      );
      final closing = gate.close();
      var planned = false;
      expect(
        gate.offer(event(1002), () {
          planned = true;
          return () async {};
        }),
        isFalse,
      );
      expect(planned, isFalse);
      release.complete();
      await closing;
      expect(writes, [1000]);
      expect(gate.failedApplies, 0);
      expect(gate.pendingSlots, 0);
    },
  );
}
