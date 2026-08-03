// Multi-device brick 1 (doc/MULTIDEVICE-DESIGN.md): the sync-event codec and
// its deterministic last-write-wins fold.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/device_sync.dart';

/// Drain the microtask queue: the gate's per-key chain hands work to the event
/// loop, so a synchronous assertion right after [DeviceSyncApplyGate.offer]
/// would be reading the state before the applier has had a turn.
Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  DeviceSyncEvent ev(DeviceSyncKind k, String key, int ts,
          [Map<String, dynamic> p = const {}]) =>
      DeviceSyncEvent(kind: k, key: key, tsMs: ts, payload: p);

  test('body codec round-trips every kind', () {
    for (final k in DeviceSyncKind.values) {
      final e = ev(k, 'id-1', 42, {'a': 1, 'b': 'x'});
      final rt = DeviceSyncEvent.fromBody(e.toBody())!;
      expect(rt.kind, k);
      expect(rt.key, 'id-1');
      expect(rt.tsMs, 42);
      expect(rt.payload, {'a': 1, 'b': 'x'});
    }
  });

  test('fromBody rejects malformed / unknown-vocabulary bodies', () {
    expect(DeviceSyncEvent.fromBody('not json'), isNull);
    expect(DeviceSyncEvent.fromBody('[]'), isNull);
    expect(DeviceSyncEvent.fromBody('{"k":"laterKind","id":"x","ts":1}'),
        isNull, reason: 'a newer vocabulary is skipped, not crashed on');
    expect(DeviceSyncEvent.fromBody('{"k":"readMark","id":"","ts":1}'), isNull);
    expect(
        DeviceSyncEvent.fromBody('{"k":"readMark","id":"p","ts":"soon"}'),
        isNull);
  });

  test('fold keeps the newest event per (kind, key), order-independent', () {
    final a1 = ev(DeviceSyncKind.readMark, 'peer-a', 10, {'wm': 10});
    final a2 = ev(DeviceSyncKind.readMark, 'peer-a', 20, {'wm': 20});
    final b1 = ev(DeviceSyncKind.settingSet, 'theme', 15, {'v': 'dark'});
    final m1 = ev(DeviceSyncKind.msgMirror, 'peer-a', 5, {'body': 'hi'});

    final f1 = foldDeviceSync([a1, a2, b1, m1]);
    final f2 = foldDeviceSync([m1, b1, a2, a1]);
    for (final f in [f1, f2]) {
      expect(f.length, 3, reason: 'msgMirror and readMark share a key but '
          'not a kind — they never collide');
      expect(f[(DeviceSyncKind.readMark, 'peer-a')]!.payload['wm'], 20);
      expect(f[(DeviceSyncKind.settingSet, 'theme')]!.payload['v'], 'dark');
      expect(f[(DeviceSyncKind.msgMirror, 'peer-a')]!.payload['body'], 'hi');
    }
  });

  test('an event may not take effect before its own timestamp, give or take '
      'the tolerated skew (XV-12)', () {
    const now = 1700000000000;
    const skew = kDeviceSyncClockSkew;
    bool effective(int ts) =>
        deviceSyncEffectiveAt(ev(DeviceSyncKind.settingSet, 'k', ts), now);

    expect(effective(now - 1), isTrue);
    expect(effective(now), isTrue);
    expect(effective(now + skew.inMilliseconds), isTrue,
        reason: 'a device exactly at the tolerated skew is still believed');
    expect(effective(now + skew.inMilliseconds + 1), isFalse);
    expect(effective(now + const Duration(days: 365).inMilliseconds), isFalse);

    // Deferral, not rejection: the SAME event becomes effective once the
    // receiving clock reaches it, so nothing an honest device wrote is lost.
    final ahead = ev(DeviceSyncKind.settingSet, 'k', now + 600000);
    expect(deviceSyncEffectiveAt(ahead, now), isFalse);
    expect(deviceSyncEffectiveAt(ahead, now + 600000), isTrue);
  });

  test('the apply gate moves a slot only for events it actually applied — a '
      'refused event must not eat the honest one behind it (XV-12)', () async {
    const now = 1700000000000;
    final gate = DeviceSyncApplyGate(nowMs: () => now);
    final applied = <String>[];
    final planned = <int>[];

    // The shape the bridge sees: a settingSet body is well-formed enough to
    // parse, but its value can still be unappliable, and the applier is the
    // only thing that can tell.
    DeviceSyncEvent setting(Object? value, int ts) => DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: 'theme',
          tsMs: ts,
          payload: {'v': value},
        );
    bool offer(DeviceSyncEvent e) => gate.offer(e, () {
          planned.add(e.tsMs);
          final v = e.payload['v'];
          if (v is! String) return null; // refused — cannot be applied
          return () async => applied.add(v);
        });

    // A compromised device posts a well-formed but unappliable event, stamped
    // as far ahead as the skew bound still believes.
    const poison = now + 200000;
    expect(offer(setting(42, poison)), isFalse);
    await _pump();
    expect(applied, isEmpty);

    // Every honest edit after it is ranked OLDER than that stamp. All of them
    // must still land: the refused event left nothing behind.
    expect(offer(setting('dark', now)), isTrue);
    expect(offer(setting('light', now + 1)), isTrue);
    await _pump();
    expect(applied, ['dark', 'light']);

    // The newest-wins rule still bites for events that DID apply.
    expect(offer(setting('stale', now)), isFalse,
        reason: 'older than what landed');
    await _pump();
    expect(applied, ['dark', 'light']);

    // And an event past the clock bound is refused before the applier is even
    // consulted — it cannot take a slot by being asked about.
    planned.clear();
    expect(offer(setting('year-ahead', now + 31536000000)), isFalse);
    await _pump();
    expect(planned, isEmpty, reason: 'not effective yet — never planned');
    expect(applied, ['dark', 'light']);
  });

  test('one key applies serially, different keys apply in parallel — deciding '
      'an order and then starting the work concurrently decides nothing '
      '(XV-12)', () async {
    const now = 1700000000000;
    final gate = DeviceSyncApplyGate(nowMs: () => now);
    final started = <String>[];
    final finished = <String>[];
    // An explicit valve per apply. The window a same-key race needs must be
    // HELD open by the test, never hoped for from the scheduler.
    final release = {
      for (final tag in ['a1', 'a2', 'b1']) tag: Completer<void>(),
    };

    bool offer(String key, String tag, int ts) => gate.offer(
          DeviceSyncEvent(
            kind: DeviceSyncKind.settingSet,
            key: key,
            tsMs: ts,
            payload: {'v': tag},
          ),
          () => () async {
            started.add(tag);
            await release[tag]!.future;
            finished.add(tag);
          },
        );

    // Two events on the SAME slot back to back — how a catch-up burst or a
    // re-drive arrives on the incoming stream. Both beat the newest-wins
    // guard, so both are admitted; only one may be in flight.
    expect(offer('theme', 'a1', now), isTrue);
    expect(offer('theme', 'a2', now + 1), isTrue);
    await _pump();
    expect(started, ['a1'],
        reason: 'the second apply of a key waits for the first to finish');

    // A DIFFERENT key must not wait behind it: the queue is keyed, not a
    // global serializer that would stall a whole catch-up on one slow write.
    expect(offer('locale', 'b1', now), isTrue);
    await _pump();
    expect(started, ['a1', 'b1']);
    expect(finished, isEmpty);

    // Releasing the first lets the second in — in the order they were admitted,
    // which is the order the newest-wins guard ranked them.
    release['a1']!.complete();
    await _pump();
    expect(started, ['a1', 'b1', 'a2']);
    expect(finished, ['a1']);

    release['a2']!.complete();
    release['b1']!.complete();
    await _pump();
    expect(finished, containsAll(<String>['a1', 'a2', 'b1']));
    expect(gate.pendingSlots, 0,
        reason: 'a drained slot must not stay in the chain map');
  });

  test('equal timestamps break ties deterministically on payload', () {
    final x = ev(DeviceSyncKind.settingSet, 'k', 7, {'v': 'aaa'});
    final y = ev(DeviceSyncKind.settingSet, 'k', 7, {'v': 'zzz'});
    final w1 = foldDeviceSync([x, y])[(DeviceSyncKind.settingSet, 'k')]!;
    final w2 = foldDeviceSync([y, x])[(DeviceSyncKind.settingSet, 'k')]!;
    expect(w1.payload, w2.payload, reason: 'devices must agree on the winner');
    expect(w1.payload['v'], 'zzz');
  });
}
