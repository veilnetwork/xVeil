import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_mirror_lease.dart';

void main() {
  test(
    'stop cancels a candidate still opening and closes its late handle',
    () async {
      final lease = CallAudioMirrorLease();
      final opening = Completer<int?>();
      final closed = <int>[];
      var qualifications = 0;
      final result = lease.start(
        duration: const Duration(seconds: 30),
        stillOwned: () => true,
        openAlternate: () => opening.future,
        qualify: (_) async {
          qualifications++;
          return true;
        },
        bind: (_) => throw StateError('must not bind'),
        close: closed.add,
      );
      lease.stop();
      opening.complete(7);
      expect((await result)['reason'], 'call_changed');
      expect(closed, [7]);
      expect(qualifications, 0);
    },
  );

  test(
    'handover during qualification keeps the active sender intact',
    () async {
      final lease = CallAudioMirrorLease();
      final qualification = Completer<bool>();
      final entered = Completer<void>();
      final closed = <int>[];
      var owned = true;
      final result = lease.start(
        duration: const Duration(seconds: 30),
        stillOwned: () => owned,
        openAlternate: () async => 8,
        qualify: (_) {
          entered.complete();
          return qualification.future;
        },
        bind: (_) => throw StateError('must not bind'),
        close: closed.add,
      );
      await entered.future;
      owned = false;
      qualification.complete(true);
      expect((await result)['reason'], 'call_changed');
      expect(closed, [8]);
    },
  );

  test('unconfirmed delivery and failed bind release candidate', () async {
    for (final confirmed in [false, true]) {
      final lease = CallAudioMirrorLease();
      final closed = <int>[];
      final result = await lease.start(
        duration: const Duration(seconds: 30),
        stillOwned: () => true,
        openAlternate: () async => 9,
        qualify: (_) async => confirmed,
        bind: (_) => false,
        close: closed.add,
      );
      expect(
        result['reason'],
        confirmed ? 'bind_failed' : 'delivery_unconfirmed',
      );
      expect(closed, [9]);
      expect(lease.enabled, false);
    }
  });

  test('concurrent enable cannot open another candidate', () async {
    final lease = CallAudioMirrorLease();
    final opening = Completer<int?>();
    var opens = 0;
    Future<Map<String, Object?>> start() => lease.start(
      duration: const Duration(seconds: 30),
      stillOwned: () => true,
      openAlternate: () {
        opens++;
        return opening.future;
      },
      qualify: (_) async => true,
      bind: (_) => true,
      close: (_) {},
    );
    final first = start();
    expect((await start())['reason'], 'busy');
    opening.complete(10);
    expect((await first)['ok'], true);
    expect(opens, 1);
    lease.stop();
  });

  test(
    'expiration disables native duplication before closing borrowed handle',
    () {
      fakeAsync((clock) {
        final lease = CallAudioMirrorLease();
        final events = <String>[];
        lease.start(
          duration: const Duration(seconds: 30),
          stillOwned: () => true,
          openAlternate: () async => 11,
          qualify: (_) async => true,
          bind: (c) {
            events.add('bind:$c');
            return true;
          },
          close: (c) => events.add('close:$c'),
        );
        clock.flushMicrotasks();
        expect(lease.enabled, true);
        expect(events, ['bind:11']);
        clock.elapse(const Duration(seconds: 29));
        expect(lease.enabled, true);
        clock.elapse(const Duration(seconds: 1));
        expect(lease.enabled, false);
        expect(events, ['bind:11', 'bind:0', 'close:11']);
        lease.stop();
        expect(events.length, 3);
      });
    },
  );
}
