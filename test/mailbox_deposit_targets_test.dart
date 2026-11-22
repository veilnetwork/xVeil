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
Future<ResolvedMailboxRelayKey?> _noDirectory(NodeId relay) async => null;

ResolvedMailboxRelayKey _resolved(int seed) =>
    (key: _kem(seed), validUntilUnix: 0);

class _ObservedRelayKeyCache extends InMemoryRelayKeyCache {
  var writes = 0;

  @override
  Future<void> put(NodeId relay, Uint8List key, {int validUntilUnix = 0}) {
    writes++;
    return super.put(relay, key, validUntilUnix: validUntilUnix);
  }
}

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
        plan: plan,
        cache: cache,
      );
      expect((await cache.getPeerRelays(peer)).single.hex, _id(10).hex);
      expect(
        await cache.get(_id(10)),
        _kem(20),
        reason:
            'the relay key travels with the relay id, or the fallback '
            'has an address it cannot seal to',
      );
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

    test('a rotated directory key wins over a remembered key', () async {
      final receiver = _id(5);
      final relay = _id(13);
      await cache.setPeerRelays(receiver, [relay]);
      await cache.put(relay, _kem(20));

      final plan = await planMailboxDeposit(
        receiver: receiver,
        adReplicas: const [],
        resolveRelayKem: (candidate) async {
          expect(candidate, relay);
          return _resolved(23);
        },
        fanout: 3,
        cache: cache,
      );
      expect(plan.source, MailboxTargetSource.cache);
      expect(plan.targets.single.kemPk, _kem(23));
      await recordMailboxDeposit(
        receiver: receiver,
        accepted: plan.targets,
        plan: plan,
        cache: cache,
      );
      expect(await cache.get(relay), _kem(23));
    });

    test('a handoff using a cached key does not prolong it', () async {
      final receiver = _id(6);
      final relay = _id(14);
      final observed = _ObservedRelayKeyCache();
      await observed.setPeerRelays(receiver, [relay]);
      await observed.put(relay, _kem(24));
      final plan = await planMailboxDeposit(
        receiver: receiver,
        adReplicas: const [],
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: observed,
      );
      expect(plan.targets.single.kemPk, _kem(24));
      await recordMailboxDeposit(
        receiver: receiver,
        accepted: plan.targets,
        plan: plan,
        cache: observed,
      );
      expect(observed.writes, 1, reason: 'transport handoff proves no new key');
    });

    test('a remembered relay key can come from the relay directory', () async {
      final peer = _id(5);
      await cache.setPeerRelays(peer, [_id(13)]);
      final plan = await planMailboxDeposit(
        receiver: peer,
        adReplicas: const [],
        resolveRelayKem: (relay) async =>
            relay.hex == _id(13).hex ? _resolved(23) : null,
        fanout: 3,
        cache: cache,
      );
      expect(plan.source, MailboxTargetSource.cache);
      expect(plan.targets.single.kemPk, _kem(23));
    });

    test('a KEM-less ad alone does not establish mailbox service', () async {
      var lookups = 0;
      final plan = await planMailboxDeposit(
        receiver: _id(6),
        adReplicas: [(relay: _id(14), kemPk: null)],
        resolveRelayKem: (relay) async {
          lookups++;
          return _resolved(24);
        },
        fanout: 3,
        cache: cache,
      );
      expect(plan.isEmpty, isTrue);
      expect(lookups, 0);
    });

    test('a keyless view can still use a remembered mailbox relay', () async {
      final receiver = _id(6);
      final mailboxRelay = _id(16);
      await cache.setPeerRelays(receiver, [mailboxRelay]);
      final plan = await planMailboxDeposit(
        receiver: receiver,
        adReplicas: [(relay: _id(14), kemPk: null)],
        resolveRelayKem: (relay) async {
          expect(relay, mailboxRelay);
          return _resolved(26);
        },
        fanout: 3,
        cache: cache,
      );
      expect(plan.source, MailboxTargetSource.cache);
      expect(plan.targets.single.relayNodeId, mailboxRelay.bytes);
    });

    test(
      'an explicit mailbox key excludes transit-only rendezvous ads',
      () async {
        var lookups = 0;
        final plan = await planMailboxDeposit(
          receiver: _id(6),
          adReplicas: [
            (relay: _id(14), kemPk: null),
            (relay: _id(16), kemPk: _kem(26)),
          ],
          resolveRelayKem: (relay) async {
            lookups++;
            return _resolved(24);
          },
          fanout: 3,
          cache: cache,
        );
        expect(plan.targets.single.relayNodeId, _id(16).bytes);
        expect(lookups, 0);
      },
    );

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

    test('a directory key does not renew the remembered relay list', () async {
      final peer = _id(1);
      final retained = _id(10);
      final unused = _id(11);
      await cache.setPeerRelays(peer, [retained, unused]);
      final plan = await planMailboxDeposit(
        receiver: peer,
        adReplicas: const [],
        resolveRelayKem: (relay) async =>
            relay == retained ? _resolved(30) : null,
        fanout: 3,
        cache: cache,
      );
      expect(plan.targets, hasLength(1));
      await recordMailboxDeposit(
        receiver: peer,
        accepted: plan.targets,
        plan: plan,
        cache: cache,
      );
      expect(await cache.getPeerRelays(peer), [retained, unused]);
      expect(await cache.get(retained), _kem(30));
    });

    test('a fresh ad replaces the remembered relay list', () async {
      final peer = _id(2);
      await cache.setPeerRelays(peer, [_id(10), _id(11)]);
      final plan = await planMailboxDeposit(
        receiver: peer,
        adReplicas: [(relay: _id(12), kemPk: _kem(12))],
        resolveRelayKem: _noDirectory,
        fanout: 3,
        cache: cache,
      );
      await recordMailboxDeposit(
        receiver: peer,
        accepted: plan.targets,
        plan: plan,
        cache: cache,
      );
      expect(await cache.getPeerRelays(peer), [_id(12)]);
    });

    test(
      'a deposit with no accepted transport handoff writes nothing',
      () async {
        final peer = _id(3);
        final plan = await planMailboxDeposit(
          receiver: peer,
          adReplicas: [(relay: _id(12), kemPk: _kem(12))],
          resolveRelayKem: _noDirectory,
          fanout: 3,
          cache: cache,
        );
        await recordMailboxDeposit(
          receiver: peer,
          accepted: const [],
          plan: plan,
          cache: cache,
        );
        expect(await cache.getPeerRelays(peer), isEmpty);
        expect(await cache.get(_id(12)), isNull);
      },
    );
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
      await StorageRelayKeyCache(
        storage,
      ).setPeerRelays(peer, [_id(10), _id(11)]);

      // A fresh instance over the SAME space — a stack rebuild or cold launch,
      // which is exactly when the peer's ad is most likely already lapsed.
      final reopened = StorageRelayKeyCache(storage);
      expect((await reopened.getPeerRelays(peer)).map((r) => r.hex), [
        _id(10).hex,
        _id(11).hex,
      ]);
    });

    test('an entry past its TTL reads back as never-resolved', () async {
      final cache = StorageRelayKeyCache(
        storage,
        ttl: const Duration(milliseconds: 1),
      );
      await cache.setPeerRelays(_id(2), [_id(10)]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await cache.getPeerRelays(_id(2)), isEmpty);
    });

    test('only kPeerRelayCacheMaxRelays relays are kept per peer', () async {
      final cache = StorageRelayKeyCache(storage);
      await cache.setPeerRelays(_id(3), [
        for (var i = 0; i < kPeerRelayCacheMaxRelays + 3; i++) _id(40 + i),
      ]);
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
      expect(
        await cache.getPeerRelays(_id(0)),
        isEmpty,
        reason: 'the bound has to actually erase, not just stop growing',
      );
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
