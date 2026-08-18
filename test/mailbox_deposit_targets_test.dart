import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/mailbox_deposit_targets.dart';
import 'package:xveil/data/transport/relay_key_cache.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));
Uint8List _kem(int seed) => Uint8List.fromList(List.filled(32, seed));

/// No relay-directory lookup is reachable — the shape of the fallback when the
/// only key material available is what we already stored.
Future<Uint8List?> _noDirectory(NodeId relay) async => null;

void main() {
  group('deposit targets for a peer whose rendezvous ad has lapsed', () {
    late InMemoryRelayKeyCache cache;

    setUp(() => cache = InMemoryRelayKeyCache());

    test('a fresh ad is preferred and its relays are remembered', () async {
      final peer = _id(1);
      final plan = await planMailboxDeposit(
        receiver: peer,
        adReplicas: [(relay: _id(10), kemPk: _kem(20))],
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: cache,
      );
      expect(plan.source, MailboxTargetSource.freshAd);
      expect(plan.targets.single.relayNodeId, _id(10).bytes);

      await recordMailboxDeposit(
        receiver: peer,
        accepted: plan.targets,
        source: plan.source,
        cache: cache,
      );
      expect((await cache.getPeerRelays(peer)).single.hex, _id(10).hex);
      expect(await cache.get(_id(10)), _kem(20),
          reason: 'the relay key travels with the relay id, or the fallback '
              'has an address it cannot seal to');
    });

    test('an unresolvable ad falls back to the remembered relays', () async {
      final peer = _id(2);
      await cache.setPeerRelays(peer, [_id(11)]);
      await cache.put(_id(11), _kem(21));

      final plan = await planMailboxDeposit(
        receiver: peer,
        adReplicas: const [], // the peer has been off longer than its ad lives
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: cache,
      );
      expect(plan.source, MailboxTargetSource.cache);
      expect(plan.targets.single.relayNodeId, _id(11).bytes);
      expect(plan.targets.single.kemPk, _kem(21));
    });

    test('a peer with neither an ad nor a cache entry has NO target — which '
        'is what leaves the unresolved-peer backoff in charge', () async {
      final plan = await planMailboxDeposit(
        receiver: _id(3),
        adReplicas: const [],
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: cache,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.source, MailboxTargetSource.none);
    });

    test('a remembered relay whose key is gone is not a target', () async {
      final peer = _id(4);
      await cache.setPeerRelays(peer, [_id(12)]);
      // No cache.put for _id(12) and no directory: nothing to seal the PUT to.
      final plan = await planMailboxDeposit(
        receiver: peer,
        adReplicas: const [],
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: cache,
      );
      expect(plan.isEmpty, isTrue);
    });

    test('a remembered relay key can come from the relay directory', () async {
      final peer = _id(5);
      await cache.setPeerRelays(peer, [_id(13)]);
      final plan = await planMailboxDeposit(
        receiver: peer,
        adReplicas: const [],
        resolveRelayKem: (relay) async =>
            relay.hex == _id(13).hex ? _kem(23) : null,
        fanout: 3,
        cache: cache,
      );
      expect(plan.source, MailboxTargetSource.cache);
      expect(plan.targets.single.kemPk, _kem(23));
    });

    test('a KEM-less ad still names the relay', () async {
      final plan = await planMailboxDeposit(
        receiver: _id(6),
        adReplicas: [(relay: _id(14), kemPk: null)],
        resolveRelayKem: (relay) async => _kem(24),
        fanout: 3,
        cache: cache,
      );
      expect(plan.source, MailboxTargetSource.freshAd);
      expect(plan.targets.single.kemPk, _kem(24));
    });

    test('the fanout bounds how many relays one deposit pays for', () async {
      final plan = await planMailboxDeposit(
        receiver: _id(7),
        adReplicas: [
          for (var i = 0; i < 6; i++) (relay: _id(30 + i), kemPk: _kem(40 + i)),
        ],
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: cache,
      );
      expect(plan.targets, hasLength(3));
    });

    test('a duplicate relay across ad slots is deposited to once', () async {
      final plan = await planMailboxDeposit(
        receiver: _id(8),
        adReplicas: [
          (relay: _id(15), kemPk: _kem(25)),
          (relay: _id(15), kemPk: _kem(25)),
        ],
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: cache,
      );
      expect(plan.targets, hasLength(1));
    });
  });

  group('what a deposit is allowed to write back', () {
    late InMemoryRelayKeyCache cache;

    setUp(() => cache = InMemoryRelayKeyCache());

    test('a cache-sourced deposit does NOT renew the peer record', () async {
      final peer = _id(1);
      await cache.setPeerRelays(peer, [_id(10)]);
      await recordMailboxDeposit(
        receiver: peer,
        accepted: [(relayNodeId: _id(99).bytes, kemPk: _kem(99))],
        source: MailboxTargetSource.cache,
        cache: cache,
      );
      expect((await cache.getPeerRelays(peer)).single.hex, _id(10).hex,
          reason: 'our own retries must not keep a relay the peer abandoned '
              'alive forever — only the peer\'s own ad may write this record');
      expect(await cache.get(_id(99)), _kem(99),
          reason: 'a relay key is a fact about the relay, not about the '
              'peer\'s choice of it, so it is cached either way');
    });

    test('a fresh ad overwrites the record wholesale, so a peer that moved '
        'relays stops being deposited at the old one', () async {
      final peer = _id(2);
      await cache.setPeerRelays(peer, [_id(10), _id(11)]);
      await recordMailboxDeposit(
        receiver: peer,
        accepted: [(relayNodeId: _id(12).bytes, kemPk: _kem(12))],
        source: MailboxTargetSource.freshAd,
        cache: cache,
      );
      expect(
        (await cache.getPeerRelays(peer)).map((r) => r.hex),
        [_id(12).hex],
      );
    });

    test('a deposit that reached nobody writes nothing', () async {
      final peer = _id(3);
      await recordMailboxDeposit(
        receiver: peer,
        accepted: const [],
        source: MailboxTargetSource.freshAd,
        cache: cache,
      );
      expect(await cache.getPeerRelays(peer), isEmpty);
    });
  });

  group('the per-peer record is bounded and survives a restart', () {
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

    test('a remembered relay set is readable by a fresh cache over the same '
        'space', () async {
      final peer = _id(1);
      await StorageRelayKeyCache(storage).setPeerRelays(peer, [_id(10), _id(11)]);

      // A fresh instance over the SAME space — a stack rebuild or cold launch,
      // which is exactly when the peer's ad is most likely already lapsed.
      final reopened = StorageRelayKeyCache(storage);
      expect(
        (await reopened.getPeerRelays(peer)).map((r) => r.hex),
        [_id(10).hex, _id(11).hex],
      );
    });

    test('an entry past its TTL reads back as never-resolved', () async {
      final cache =
          StorageRelayKeyCache(storage, ttl: const Duration(milliseconds: 1));
      await cache.setPeerRelays(_id(2), [_id(10)]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await cache.getPeerRelays(_id(2)), isEmpty);
    });

    test('only kPeerRelayCacheMaxRelays relays are kept per peer', () async {
      final cache = StorageRelayKeyCache(storage);
      await cache.setPeerRelays(
        _id(3),
        [for (var i = 0; i < kPeerRelayCacheMaxRelays + 3; i++) _id(40 + i)],
      );
      expect(
        await cache.getPeerRelays(_id(3)),
        hasLength(kPeerRelayCacheMaxRelays),
      );
    });

    test('the peer set is bounded — the oldest entry is erased, the newest '
        'kept', () async {
      final cache = StorageRelayKeyCache(storage);
      // Peer ids are the loop index, so peer 0 is the oldest insertion.
      for (var i = 0; i <= kPeerRelayCacheMaxPeers; i++) {
        await cache.setPeerRelays(_id(i), [_id(200)]);
      }
      expect(await cache.getPeerRelays(_id(0)), isEmpty,
          reason: 'the bound has to actually erase, not just stop growing');
      expect(
        await cache.getPeerRelays(_id(kPeerRelayCacheMaxPeers)),
        hasLength(1),
      );
      // The bound survives the restart too — otherwise a relaunch would
      // re-learn an unbounded set from whatever is still in the store.
      final reopened = StorageRelayKeyCache(storage);
      await reopened.setPeerRelays(_id(250), [_id(200)]);
      expect(await reopened.getPeerRelays(_id(1)), isEmpty);
    });
  });
}
