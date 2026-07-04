import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/state/mailbox_orchestrator.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));
Uint8List _cid(int s) => Uint8List.fromList(List.filled(32, s));
Uint8List _appId(int s) => Uint8List.fromList(List.filled(32, s));

void main() {
  late InMemoryMailboxRelay relay;
  late MailboxOrchestrator orch;
  final me = _id(1);
  final peer = _id(2);
  final cookie = Uint8List.fromList(List.filled(16, 7));

  setUp(() {
    relay = InMemoryMailboxRelay();
    // The loopback crypto reports `peer` as the verified sender (the real node
    // recovers it from the blob's sidecar; here every stash is from `peer`).
    orch = MailboxOrchestrator(LoopbackMailboxCrypto(senderForOpen: peer), relay);
  });

  Future<bool> never(Uint8List _) async => false;

  test('stash seals + puts; drain opens, returns, and acks', () async {
    final data = Uint8List.fromList([10, 20, 30]);
    await orch.stash(
      me: peer,
      recipient: me,
      appId: _appId(0xAA),
      endpointId: 9,
      data: data,
      contentId: _cid(0xC1),
    );
    // The blob is now pending for `me`.
    expect((await relay.fetch(me: me, authCookie: cookie)), hasLength(1));

    final drained = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: never,
    );
    expect(drained, hasLength(1));
    expect(drained.single.data, data);
    expect(drained.single.endpointId, 9);
    expect(drained.single.appId, _appId(0xAA));
    expect(drained.single.sender, peer);
    // Acked → relay drained.
    expect((await relay.fetch(me: me, authCookie: cookie)), isEmpty);
  });

  test('drain dedups: a blob we already have is skipped but still acked',
      () async {
    await orch.stash(
      me: peer,
      recipient: me,
      appId: _appId(1),
      endpointId: 0,
      data: Uint8List.fromList([1]),
      contentId: _cid(0xC2),
    );
    final drained = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: (c) async => true, // we already stored this message live
    );
    expect(drained, isEmpty); // not re-delivered
    expect((await relay.fetch(me: me, authCookie: cookie)), isEmpty); // but acked
  });

  test('drain acks + skips a corrupt blob without wedging the inbox', () async {
    // A malformed blob (too short to open) deposited directly + a good one.
    await relay.put(
      receiver: me,
      contentId: _cid(0xBA),
      sender: peer,
      blob: Uint8List.fromList([0, 1, 2]), // < 36 bytes -> open throws
    );
    await orch.stash(
      me: peer,
      recipient: me,
      appId: _appId(2),
      endpointId: 3,
      data: Uint8List.fromList([42]),
      contentId: _cid(0xC3),
    );

    final drained = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: never,
    );
    // The good one is delivered; the corrupt one is dropped — both acked.
    expect(drained, hasLength(1));
    expect(drained.single.data, Uint8List.fromList([42]));
    expect((await relay.fetch(me: me, authCookie: cookie)), isEmpty);
  });

  group('drain-until-empty (1-blob-per-fetch relay reply budget)', () {
    test('one drain() collects a whole queued backlog, oldest-first', () async {
      final budgeted = _OneBlobPerFetchRelay();
      final orch = MailboxOrchestrator(
        LoopbackMailboxCrypto(senderForOpen: peer),
        budgeted,
      );
      for (var i = 0; i < 5; i++) {
        await orch.stash(
          me: peer,
          recipient: me,
          appId: _appId(1),
          endpointId: 2,
          data: Uint8List.fromList([i]),
          contentId: _cid(0x30 + i),
        );
      }
      final drained = await orch.drain(
          me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never);
      expect(drained, hasLength(5),
          reason: 'the documented contract is re-fetch after acking — a '
              'backlog must not trickle out one blob per drain TICK');
      expect(drained.map((d) => d.data.single), [0, 1, 2, 3, 4]);
      expect(await budgeted.fetch(me: me, authCookie: cookie), isEmpty);
    });

    test('a junk backlog is fully quarantined+acked in one drain — it must '
        'not look like a live producer of one fresh cid per drain', () async {
      var opens = 0;
      final budgeted = _OneBlobPerFetchRelay();
      final orch = MailboxOrchestrator(
        _CountingOpenCrypto(
          LoopbackMailboxCrypto(senderForOpen: peer),
          onOpen: () => opens++,
        ),
        budgeted,
      );
      for (var i = 0; i < 4; i++) {
        await budgeted.put(
          receiver: me,
          contentId: _cid(0x60 + i),
          sender: peer,
          blob: Uint8List.fromList([0, 1]), // undecryptable
        );
      }
      expect(
        await orch.drain(
            me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never),
        isEmpty,
      );
      expect(opens, 4, reason: 'each junk blob pays exactly one open');
      expect(await budgeted.fetch(me: me, authCookie: cookie), isEmpty,
          reason: 'the whole junk backlog is acked away in one drain');
    });

    test('an ack-ignoring relay cannot spin the loop forever', () async {
      final sticky = _AckIgnoringOneBlobRelay();
      final orch = MailboxOrchestrator(
        LoopbackMailboxCrypto(senderForOpen: peer),
        sticky,
      );
      await sticky.put(
        receiver: me,
        contentId: _cid(0x77),
        sender: peer,
        blob: Uint8List.fromList([0, 1]), // undecryptable, never removed
      );
      // Must terminate (the same cid is not "fresh" twice within one drain).
      // A relay re-serving an already-handled blob triggers a bounded set of
      // ack-settle retries (the throughput fix that lets a correct relay's
      // whole backlog clear in one drain) — an ack-IGNORING relay just exhausts
      // that small budget and stops, never spinning forever.
      expect(
        await orch.drain(
            me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never),
        isEmpty,
      );
      expect(sticky.fetchCalls, lessThanOrEqualTo(9));
    });
  });

  group('poisoned-blob quarantine', () {
    // Storage stub for the registry (real one rides the settings KV).
    late Map<String, String> settings;
    PoisonedBlobRegistry freshRegistry() => PoisonedBlobRegistry(
          getSetting: (k) async => settings[k],
          putSetting: (k, v) async => settings[k] = v,
        );

    setUp(() => settings = {});

    test(
        'an undecryptable blob is opened ONCE, quarantined durably, and '
        'skipped on every later drain (relay that ignores acks)', () async {
      var opens = 0;
      final counting = _CountingOpenCrypto(
        LoopbackMailboxCrypto(senderForOpen: peer),
        onOpen: () => opens++,
      );
      // A relay that ignores acks — models today's deployed relays (no ack
      // endpoint): the poisoned blob is re-served on EVERY fetch.
      final stickyRelay = _AckIgnoringRelay();
      final orch = MailboxOrchestrator(
        counting,
        stickyRelay,
        poisoned: freshRegistry(),
      );
      await stickyRelay.put(
        receiver: me,
        contentId: _cid(0xDE),
        sender: peer,
        blob: Uint8List.fromList([0, 1, 2]), // undecryptable forever
      );

      expect(
        await orch.drain(
            me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never),
        isEmpty,
      );
      expect(opens, 1, reason: 'first sighting pays the open');

      for (var i = 0; i < 3; i++) {
        expect(
          await orch.drain(
              me: me,
              authCookie: cookie,
              ourCertVersion: 1,
              alreadyHave: never),
          isEmpty,
        );
      }
      expect(opens, 1,
          reason: 'quarantined cid must never be decrypt-attempted again');

      // Durable: a NEW orchestrator over the SAME settings (app relaunch)
      // still skips the decrypt.
      final orch2 = MailboxOrchestrator(
        counting,
        stickyRelay,
        poisoned: freshRegistry(),
      );
      await orch2.drain(
          me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never);
      expect(opens, 1, reason: 'quarantine survives a relaunch');
    });

    test(
        'an IPC-timeout open is NOT acked away — the blob survives at the '
        'relay and delivers once the node answers', () async {
      // Models the observed loss: the node's mailbox_open IPC times out while
      // the runtime is busy/starting. The old path quarantined + ACKed on ANY
      // open exception — the ack dropped the relay's only copy, permanently
      // destroying a legitimate message ("blob fetched+ACKed yet the message
      // never surfaced").
      var timeoutsLeft = 2;
      var opens = 0;
      final inner = LoopbackMailboxCrypto(senderForOpen: peer);
      final flaky = _FlakyOpenCrypto(
        inner,
        onOpen: () => opens++,
        shouldFail: () => timeoutsLeft-- > 0,
      );
      final sticky = InMemoryMailboxRelay();
      final orch2 = MailboxOrchestrator(flaky, sticky, poisoned: freshRegistry());
      final data = Uint8List.fromList([42]);
      final blob = await inner.seal(
          recipient: me, appId: _appId(0xAB), endpointId: 7, data: data);
      await sticky.put(
          receiver: me, contentId: _cid(0xAB), sender: peer, blob: blob);

      // Two drains hit the timeout: nothing delivered, nothing acked away.
      for (var i = 0; i < 2; i++) {
        expect(
          await orch2.drain(
              me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never),
          isEmpty,
        );
        expect(await sticky.fetch(me: me, authCookie: cookie), hasLength(1),
            reason: 'a TRANSIENT open failure must not ack the blob away');
      }
      // Node answers now — the message is recovered intact.
      final got = await orch2.drain(
          me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never);
      expect(got, hasLength(1));
      expect(got.single.data, data);
      expect(await sticky.fetch(me: me, authCookie: cookie), isEmpty,
          reason: 'acked only after the successful open');
      expect(opens, 3);
    });

    test('opens that time out forever still terminate (bounded → quarantine)',
        () async {
      var opens = 0;
      final inner = LoopbackMailboxCrypto(senderForOpen: peer);
      final flaky = _FlakyOpenCrypto(
        inner,
        onOpen: () => opens++,
        shouldFail: () => true, // never recovers
      );
      final sticky = InMemoryMailboxRelay();
      final orch2 = MailboxOrchestrator(flaky, sticky, poisoned: freshRegistry());
      final blob = await inner.seal(
          recipient: me, appId: _appId(0xAC), endpointId: 7,
          data: Uint8List.fromList([1]));
      await sticky.put(
          receiver: me, contentId: _cid(0xAC), sender: peer, blob: blob);

      // Retried across drains up to the cap, then treated as permanent.
      for (var i = 0; i < 6; i++) {
        await orch2.drain(
            me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never);
      }
      expect(await sticky.fetch(me: me, authCookie: cookie), isEmpty,
          reason: 'after the transient cap the blob is quarantined + acked');
      final opensAtCap = opens;
      await orch2.drain(
          me: me, authCookie: cookie, ourCertVersion: 1, alreadyHave: never);
      expect(opens, opensAtCap,
          reason: 'quarantined cid is never decrypt-attempted again');
    });

    test('quarantine is FIFO-capped so junk deposits cannot grow the registry',
        () async {
      final reg = freshRegistry();
      for (var i = 0; i < 80; i++) {
        await reg.add(_cid(i));
      }
      // Oldest evicted, newest kept (cap = 64).
      expect(await reg.contains(_cid(0)), isFalse);
      expect(await reg.contains(_cid(79)), isTrue);
      final stored = settings['mailbox.poisoned.v1']!;
      expect(RegExp('"').allMatches(stored).length ~/ 2, 64);
    });
  });
}

/// Open fails with the node's IPC-timeout error while [shouldFail] says so —
/// models a busy/starting runtime that doesn't answer `mailbox_open` (the
/// error TEXT carries the "timeout" discriminant the orchestrator keys on).
class _FlakyOpenCrypto implements VeilMailboxCrypto {
  _FlakyOpenCrypto(this._inner, {required this.onOpen, required this.shouldFail});
  final VeilMailboxCrypto _inner;
  final void Function() onOpen;
  final bool Function() shouldFail;

  @override
  Future<Uint8List> seal({
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
  }) =>
      _inner.seal(
          recipient: recipient,
          appId: appId,
          endpointId: endpointId,
          data: data);

  @override
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  }) {
    onOpen();
    if (shouldFail()) {
      throw Exception(
          'mailbox_open failed: protocol error: timeout waiting for '
          'mailbox_open reply');
    }
    return _inner.open(blob: blob, ourCertVersion: ourCertVersion);
  }
}

/// Counts decrypt attempts so tests can prove the quarantine short-circuits.
class _CountingOpenCrypto implements VeilMailboxCrypto {
  _CountingOpenCrypto(this._inner, {required this.onOpen});
  final VeilMailboxCrypto _inner;
  final void Function() onOpen;

  @override
  Future<Uint8List> seal({
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
  }) =>
      _inner.seal(
          recipient: recipient,
          appId: appId,
          endpointId: endpointId,
          data: data);

  @override
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  }) {
    onOpen();
    return _inner.open(blob: blob, ourCertVersion: ourCertVersion);
  }
}

/// An [InMemoryMailboxRelay] whose ack is a NO-OP — models the deployed relays
/// that predate the network ack endpoint and re-serve every blob until TTL.
class _AckIgnoringRelay extends InMemoryMailboxRelay {
  @override
  Future<void> ack({
    required NodeId me,
    required Uint8List contentId,
    required Uint8List authCookie,
    List<NodeId> knownRelays = const [],
  }) async {}
}

/// Models the real relay's reply budget: a FETCH reply fits ONE ~4 KB blob, so
/// a backlog is served strictly one-at-a-time (oldest first).
class _OneBlobPerFetchRelay extends InMemoryMailboxRelay {
  int fetchCalls = 0;

  @override
  Future<List<StoredMailboxBlob>> fetch({
    required NodeId me,
    required Uint8List authCookie,
    List<NodeId> knownRelays = const [],
  }) async {
    fetchCalls++;
    final all = await super.fetch(
        me: me, authCookie: authCookie, knownRelays: knownRelays);
    return all.isEmpty ? const [] : [all.first];
  }
}

/// Budget-1 relay that ALSO ignores acks — the worst case the drain loop must
/// still terminate on (an old relay re-serving the same head blob forever).
class _AckIgnoringOneBlobRelay extends _OneBlobPerFetchRelay {
  @override
  Future<void> ack({
    required NodeId me,
    required Uint8List contentId,
    required Uint8List authCookie,
    List<NodeId> knownRelays = const [],
  }) async {}
}
