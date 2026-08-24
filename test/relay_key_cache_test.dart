import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/relay_key_cache.dart';

/// A space whose writes fail while [failing] is true, and whose reads are real.
class _WriteMayFail extends HiddenVolumeStorage {
  _WriteMayFail(super.opener);

  bool failing = false;

  @override
  Future<void> putSetting(String key, String value) {
    if (failing) {
      return Future<void>.error(StateError('write failed'));
    }
    return super.putSetting(key, value);
  }
}

NodeId _relay(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));
Uint8List _key(int seed) => Uint8List.fromList(List.filled(32, seed));

void main() {
  group('StorageRelayKeyCache (deniable settings KV)', () {
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

    test('round-trips a verified key and survives a reopen', () async {
      final cache = StorageRelayKeyCache(storage);
      final relay = _relay(7);
      expect(await cache.get(relay), isNull, reason: 'cold cache is a miss');

      await cache.put(relay, _key(42));
      expect(await cache.get(relay), equals(_key(42)));

      // A fresh cache instance over the SAME space (mirrors a stack rebuild /
      // cold restart) must still read the persisted key.
      final reopened = StorageRelayKeyCache(storage);
      expect(await reopened.get(relay), equals(_key(42)));
    });

    test('expired entries read back as a miss', () async {
      final cache = StorageRelayKeyCache(
        storage,
        ttl: const Duration(milliseconds: 1),
      );
      final relay = _relay(8);
      await cache.put(relay, _key(9));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
        await cache.get(relay),
        isNull,
        reason: 'a key past its TTL must not be served',
      );
    });

    /// The shadow exists to skip a write that is already on disk. A write that
    /// FAILED is exactly when it is not, and the shadow used to be set before
    /// the write anyway — under a comment claiming a failure "just means we
    /// resolve fresh next time". It meant the opposite: the shadow then claimed
    /// a full TTL, so the same-key skip swallowed every retry for half of one.
    test('a failed write does not suppress the next attempt', () async {
      final store = FakeKvLogStore();
      final space = _WriteMayFail(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : store,
      );
      await space.open(password: 'pw', createIfMissing: true);

      final cache = StorageRelayKeyCache(space);
      final relay = _relay(21);

      space.failing = true;
      await cache.put(relay, _key(22));
      expect(
        await cache.get(relay),
        isNull,
        reason: 'nothing was stored, so nothing may be served',
      );

      // The very next put, with the same key, must actually try again.
      space.failing = false;
      await cache.put(relay, _key(22));
      expect(
        await cache.get(relay),
        equals(_key(22)),
        reason:
            'the retry has to reach storage, not be skipped as "already there"',
      );
    });

    /// Same defect on the preferred-relay half, where it was worse: the guard
    /// it fools is the first line of the method, so a failed write suppressed
    /// every retry for the rest of the PROCESS.
    test('a failed preferred-relay write does not stick as done', () async {
      final store = FakeKvLogStore();
      final space = _WriteMayFail(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : store,
      );
      await space.open(password: 'pw', createIfMissing: true);

      final cache = StorageRelayKeyCache(space);
      final relay = _relay(23);

      space.failing = true;
      await cache.setPreferredRelay(relay);
      expect(await cache.getPreferredRelay(), isNull);

      space.failing = false;
      await cache.setPreferredRelay(relay);
      expect(
        (await cache.getPreferredRelay())?.hex,
        relay.hex,
        reason: 'cross-session drift is what this preference exists to stop',
      );
    });

    test('evict drops the cached key', () async {
      final cache = StorageRelayKeyCache(storage);
      final relay = _relay(3);
      await cache.put(relay, _key(4));
      expect(await cache.get(relay), isNotNull);
      await cache.evict(relay);
      expect(await cache.get(relay), isNull);
    });

    test('keys are isolated per relay node-id', () async {
      final cache = StorageRelayKeyCache(storage);
      await cache.put(_relay(1), _key(11));
      await cache.put(_relay(2), _key(22));
      expect(await cache.get(_relay(1)), equals(_key(11)));
      expect(await cache.get(_relay(2)), equals(_key(22)));
    });

    test('a wrong-length key is never stored', () async {
      final cache = StorageRelayKeyCache(storage);
      final relay = _relay(5);
      await cache.put(relay, Uint8List.fromList(List.filled(16, 1)));
      expect(await cache.get(relay), isNull);
    });

    test(
      'the cached key is erased when the space is wiped (deniable)',
      () async {
        final cache = StorageRelayKeyCache(storage);
        final relay = _relay(6);
        await cache.put(relay, _key(60));
        expect(await cache.get(relay), isNotNull);
        // Erasing the SETTINGS namespace (what eraseSpace does to user data)
        // takes the relay-key cache with it — it carries no out-of-band copy.
        store.eraseNamespace(Ns.settings);
        expect(await cache.get(relay), isNull);
      },
    );
  });

  group('InMemoryRelayKeyCache', () {
    test('round-trips, expires, and evicts', () async {
      final cache = InMemoryRelayKeyCache(
        ttl: const Duration(milliseconds: 20),
      );
      final relay = _relay(1);
      expect(await cache.get(relay), isNull);
      await cache.put(relay, _key(2));
      expect(await cache.get(relay), equals(_key(2)));
      await cache.evict(relay);
      expect(await cache.get(relay), isNull);

      await cache.put(relay, _key(2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await cache.get(relay), isNull, reason: 'TTL expiry');
    });
  });
}
