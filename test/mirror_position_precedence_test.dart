import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart' show kMaxWireSeq;
import 'package:xveil/domain/device_sync.dart';

DeviceSyncEvent _mirror({
  bool? verified,
  int at = 1000,
  Object? seq = 7,
  String? author,
  String dir = 'outgoing',
  String peer = 'peer',
}) => DeviceSyncEvent(
  kind: DeviceSyncKind.msgMirror,
  key: 'same-id',
  tsMs: at,
  payload: {
    'peer': peer,
    'dir': dir,
    'body': 'same content',
    'au': author ?? '11' * 32,
    'sq': seq,
    'pv': ?verified,
  },
);

Iterable<List<T>> _permutations<T>(List<T> items) sync* {
  if (items.isEmpty) {
    yield [];
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = List<T>.of(items)..removeAt(i);
    for (final tail in _permutations(rest)) {
      yield [items[i], ...tail];
    }
  }
}

void main() {
  test(
    'delivery precedence stays transitive across payloads and provenance',
    () {
      final events = <DeviceSyncEvent>[
        for (final verified in [null, false, true])
          for (final stamp in [1000, 2000])
            for (final status in [null, 'failed', 'delivered'])
              DeviceSyncEvent(
                kind: DeviceSyncKind.msgMirror,
                key: 'same-id',
                tsMs: stamp,
                payload: {
                  ..._mirror(verified: verified, at: stamp).payload,
                  'st': ?status,
                  'body': '$verified/$stamp/$status',
                },
              ),
      ];
      for (final a in events) {
        for (final b in events) {
          if (!isNewerDeviceSync(a, b)) continue;
          expect(isNewerDeviceSync(b, a), isFalse);
          for (final c in events) {
            if (isNewerDeviceSync(b, c)) {
              expect(isNewerDeviceSync(a, c), isTrue);
            }
          }
        }
      }
    },
  );

  test(
    'same-position terminal delivery evidence survives compaction in every order',
    () {
      final pending = _mirror(verified: true);
      DeviceSyncEvent withStatus(String status) => DeviceSyncEvent(
        kind: pending.kind,
        key: pending.key,
        tsMs: pending.tsMs,
        payload: {...pending.payload, 'st': status},
      );
      final failed = withStatus('failed'), delivered = withStatus('delivered');
      for (final order in _permutations([pending, failed, delivered])) {
        expect(
          foldDeviceSync(order)[(pending.kind, pending.key)],
          same(delivered),
        );
      }
      final canonicalPending = _mirror(verified: true, at: 2000);
      expect(
        isNewerDeviceSync(canonicalPending, delivered),
        isTrue,
        reason: 'delivery metadata must not change the message time ordering',
      );
      final provisional = _mirror(verified: false);
      final provisionalDelivered = DeviceSyncEvent(
        kind: provisional.kind,
        key: provisional.key,
        tsMs: 3000,
        payload: {...provisional.payload, 'st': 'delivered'},
      );
      expect(
        isNewerDeviceSync(provisionalDelivered, pending),
        isFalse,
        reason: 'delivery evidence cannot grant original-position authority',
      );
    },
  );

  test(
    'verified position wins over later legacy and provisional copies in every order',
    () {
      final canonical = _mirror(verified: true);
      final legacy = _mirror(at: 2000);
      final provisional = _mirror(verified: false, at: 3000);
      for (final order in _permutations([canonical, legacy, provisional])) {
        expect(
          foldDeviceSync(order)[(DeviceSyncKind.msgMirror, 'same-id')],
          same(canonical),
        );
      }
    },
  );

  test(
    'legacy unknown provenance beats explicitly provisional, not verified',
    () {
      final legacy = _mirror(at: 1000);
      final provisional = _mirror(verified: false, at: 2000);
      for (final order in [
        [legacy, provisional],
        [provisional, legacy],
      ]) {
        expect(
          foldDeviceSync(order)[(DeviceSyncKind.msgMirror, 'same-id')],
          same(legacy),
        );
      }
    },
  );

  test(
    'same provenance retains timestamp order and deterministic payload tie break',
    () {
      for (final pv in [null, false, true]) {
        final older = _mirror(verified: pv);
        final newer = _mirror(verified: pv, at: 2000);
        final tie = _mirror(verified: pv, at: 2000, seq: 8);
        for (final order in _permutations([older, newer, tie])) {
          expect(
            foldDeviceSync(order)[(DeviceSyncKind.msgMirror, 'same-id')],
            same(tie),
          );
        }
      }
    },
  );

  test(
    'position rank is transitive even for mismatched direction or peer in one slot',
    () {
      final canonical = _mirror(verified: true, at: 1000);
      final incoming = _mirror(verified: true, dir: 'incoming', at: 2000);
      final provisional = _mirror(verified: false, peer: 'different', at: 3000);
      for (final order in _permutations([canonical, incoming, provisional])) {
        expect(
          foldDeviceSync(order)[(DeviceSyncKind.msgMirror, 'same-id')],
          same(canonical),
        );
      }
    },
  );

  test('a flag without a valid position cannot displace a legacy row', () {
    final legacy = _mirror(at: 3000);
    for (final invalid in [
      _mirror(verified: true, author: 'invalid', at: 4000),
      _mirror(verified: true, seq: null, at: 4000),
      _mirror(verified: true, seq: -1, at: 4000),
      _mirror(verified: true, seq: kMaxWireSeq + 1, at: 4000),
    ]) {
      expect(isNewerDeviceSync(invalid, legacy), isFalse);
      expect(isNewerDeviceSync(legacy, invalid), isTrue);
    }
  });

  test(
    'provenance does not override the clock bound or affect unrelated event kinds',
    () {
      final future = _mirror(verified: true, at: 1000000);
      expect(deviceSyncEffectiveAt(future, 1), isFalse);
      final a = DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'same',
        tsMs: 1000,
        payload: const {'pv': true},
      );
      final b = DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'same',
        tsMs: 2000,
        payload: const {'pv': false},
      );
      expect(isNewerDeviceSync(a, b), isFalse);
    },
  );

  test('live apply gate uses the same precedence as restart fold', () async {
    final canonical = _mirror(verified: true);
    final provisional = _mirror(verified: false, at: 2000);
    for (final order in [
      [canonical, provisional],
      [provisional, canonical],
    ]) {
      final gate = DeviceSyncApplyGate(nowMs: () => 5000);
      DeviceSyncEvent? applied;
      for (final e in order) {
        gate.offer(
          e,
          () => () async {
            applied = e;
          },
        );
      }
      await gate.settle();
      expect(applied, same(canonical));
    }
  });
}
