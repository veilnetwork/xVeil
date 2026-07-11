// Multi-device brick 1 (doc/MULTIDEVICE-DESIGN.md): the sync-event codec and
// its deterministic last-write-wins fold.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/device_sync.dart';

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

  test('equal timestamps break ties deterministically on payload', () {
    final x = ev(DeviceSyncKind.settingSet, 'k', 7, {'v': 'aaa'});
    final y = ev(DeviceSyncKind.settingSet, 'k', 7, {'v': 'zzz'});
    final w1 = foldDeviceSync([x, y])[(DeviceSyncKind.settingSet, 'k')]!;
    final w2 = foldDeviceSync([y, x])[(DeviceSyncKind.settingSet, 'k')]!;
    expect(w1.payload, w2.payload, reason: 'devices must agree on the winner');
    expect(w1.payload['v'], 'zzz');
  });
}
