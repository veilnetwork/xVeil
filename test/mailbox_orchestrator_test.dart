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
    orch = MailboxOrchestrator(
      LoopbackMailboxCrypto(senderForOpen: peer),
      relay,
    );
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

  test(
    'drain dedups: a blob we already have is skipped but still acked',
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
      expect(
        (await relay.fetch(me: me, authCookie: cookie)),
        isEmpty,
      ); // but acked
    },
  );

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

  /// A blob that cannot be opened YET must not take the queue behind it down.
  ///
  /// An unacked blob is re-served on every fetch, and the relay fills its reply
  /// oldest-first — so the head of the queue is in every batch. Once the drain
  /// gave up on that head it skipped it forever, the round acked nothing, and
  /// the loop stopped: everything queued behind it waited for the app to be
  /// restarted, on a cause that usually clears in minutes (report14 X14-M4).
  ///
  /// The give-up is a deadline now. This pins both halves — that the stall is
  /// real while it lasts, and that it ENDS.
  group('a transiently unopenable head', () {
    test('stops blocking the tail once its back-off is spent', () async {
      final crypto = _StallsOnOneBlob(0xE1, senderForOpen: peer);
      final budgeted = _OneBlobPerFetchRelay();
      var clock = DateTime.utc(2026, 8, 25, 12);
      final orch = MailboxOrchestrator(crypto, budgeted)..now = () => clock;

      // Oldest first: the head is the one that will not open.
      for (final byte in [0xE1, 0xE2, 0xE3]) {
        await orch.stash(
          me: peer,
          recipient: me,
          appId: _appId(1),
          endpointId: 2,
          data: Uint8List.fromList([byte]),
          contentId: _cid(byte),
        );
      }

      // Drain until the head has burned its attempts and been set aside.
      var recovered = <DrainedMessage>[];
      for (var i = 0; i < 8; i++) {
        recovered = await orch.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        );
        if (recovered.isNotEmpty) break;
      }
      expect(
        recovered,
        isEmpty,
        reason:
            'while the head is unopenable and unacked it is the whole '
            'reply, so nothing behind it can be reached — this is the stall '
            'the back-off bounds, not something it prevents',
      );
      expect(
        crypto.attempts,
        greaterThan(0),
        reason:
            'the fixture never even '
            'tried to open the stalled blob',
      );

      // The network recovers, and so does the sender's document. Nothing
      // restarted; only time passed.
      crypto.recovered = true;
      clock = clock.add(const Duration(minutes: 11));

      final after = await orch.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(
        after.map((d) => d.data.single).toList(),
        [0xE1, 0xE2, 0xE3],
        reason:
            'a blob set aside for a transient reason must be tried again '
            'when the reason has had time to pass — and the queue behind it '
            'comes with it',
      );
    });

    test('is left alone while the back-off is still running', () async {
      final crypto = _StallsOnOneBlob(0xF1, senderForOpen: peer);
      final budgeted = _OneBlobPerFetchRelay();
      var clock = DateTime.utc(2026, 8, 25, 12);
      final orch = MailboxOrchestrator(crypto, budgeted)..now = () => clock;

      await orch.stash(
        me: peer,
        recipient: me,
        appId: _appId(1),
        endpointId: 2,
        data: Uint8List.fromList([0xF1]),
        contentId: _cid(0xF1),
      );
      for (var i = 0; i < 8; i++) {
        await orch.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        );
      }
      final spent = crypto.attempts;

      // Two more drains inside the cooldown must cost nothing: a failed open
      // is ~20 s of cert-resolve timeout, which is what the cap exists to stop
      // paying.
      clock = clock.add(const Duration(minutes: 1));
      for (var i = 0; i < 2; i++) {
        await orch.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        );
      }
      expect(
        crypto.attempts,
        spent,
        reason: 'retrying every drain would put back the cost the cap removed',
      );
    });
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
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(
        drained,
        hasLength(5),
        reason:
            'the documented contract is re-fetch after acking — a '
            'backlog must not trickle out one blob per drain TICK',
      );
      expect(drained.map((d) => d.data.single), [0, 1, 2, 3, 4]);
      expect(await budgeted.fetch(me: me, authCookie: cookie), isEmpty);
    });

    test('a realtime gate preempts a backlog between fetch rounds', () async {
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
          contentId: _cid(0x40 + i),
        );
      }

      var checks = 0;
      final drained = await orch.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
        // true before/after the first FETCH and for its one blob, then false
        // before round two.
        shouldContinue: () => checks++ < 3,
      );

      expect(drained.map((d) => d.data.single), [0]);
      expect(
        await budgeted.fetch(me: me, authCookie: cookie),
        hasLength(1),
        reason: 'the unprocessed backlog remains durable at the relay',
      );
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
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        ),
        isEmpty,
      );
      expect(opens, 4, reason: 'each junk blob pays exactly one open');
      expect(
        await budgeted.fetch(me: me, authCookie: cookie),
        isEmpty,
        reason: 'the whole junk backlog is acked away in one drain',
      );
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
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        ),
        isEmpty,
      );
      expect(sticky.fetchCalls, lessThanOrEqualTo(9));
    });

    test('a message is handed up while the loop is still hunting a backlog', () async {
      // The rounds after the one that produced a message are looking for a
      // BACKLOG: they re-fetch, meet the relay still serving the blob whose ack
      // is in flight, and wait for the removal to land. Returning the batch only
      // when that finished made every message wait out the search for its
      // successors -- on the stand a drain carrying one message took ~6.8s while
      // the fetch that produced it took ~0.5s.
      final sticky = _AckIgnoringOneBlobRelay();
      final orch = MailboxOrchestrator(
        LoopbackMailboxCrypto(senderForOpen: peer),
        sticky,
      );
      await orch.stash(
        me: peer,
        recipient: me,
        appId: _appId(0xAA),
        endpointId: 9,
        data: Uint8List.fromList([1, 2, 3]),
        contentId: _cid(0x5A),
      );

      DrainedMessage? handedUp;
      var fetchesWhenHandedUp = -1;
      final drained = await orch.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
        onMessage: (m) {
          handedUp = m;
          fetchesWhenHandedUp = sticky.fetchCalls;
        },
      );

      expect(handedUp, isNotNull, reason: 'the message must be handed up');
      expect(handedUp!.data, Uint8List.fromList([1, 2, 3]));
      expect(drained, hasLength(1), reason: 'the batch still carries it too');
      // The structural proof, in place of a timing race: the loop went on
      // fetching AFTER the hand-up. If delivery still waited for the loop, this
      // count would equal the total.
      expect(
        fetchesWhenHandedUp,
        lessThan(sticky.fetchCalls),
        reason:
            'the message was handed up while the drain was still fetching for '
            'a backlog, not after the whole loop finished',
      );
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

    test('an undecryptable blob is opened ONCE, quarantined durably, and '
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
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        ),
        isEmpty,
      );
      expect(opens, 1, reason: 'first sighting pays the open');

      for (var i = 0; i < 3; i++) {
        expect(
          await orch.drain(
            me: me,
            authCookie: cookie,
            ourCertVersion: 1,
            alreadyHave: never,
          ),
          isEmpty,
        );
      }
      expect(
        opens,
        1,
        reason: 'quarantined cid must never be decrypt-attempted again',
      );

      // Durable: a NEW orchestrator over the SAME settings (app relaunch)
      // still skips the decrypt.
      final orch2 = MailboxOrchestrator(
        counting,
        stickyRelay,
        poisoned: freshRegistry(),
      );
      await orch2.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(opens, 1, reason: 'quarantine survives a relaunch');
    });

    test('an IPC-timeout open is NOT acked away — the blob survives at the '
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
      final orch2 = MailboxOrchestrator(
        flaky,
        sticky,
        poisoned: freshRegistry(),
      );
      final data = Uint8List.fromList([42]);
      final blob = await inner.seal(
        recipient: me,
        appId: _appId(0xAB),
        endpointId: 7,
        data: data,
      );
      await sticky.put(
        receiver: me,
        contentId: _cid(0xAB),
        sender: peer,
        blob: blob,
      );

      // Two drains hit the timeout: nothing delivered, nothing acked away.
      for (var i = 0; i < 2; i++) {
        expect(
          await orch2.drain(
            me: me,
            authCookie: cookie,
            ourCertVersion: 1,
            alreadyHave: never,
          ),
          isEmpty,
        );
        expect(
          await sticky.fetch(me: me, authCookie: cookie),
          hasLength(1),
          reason: 'a TRANSIENT open failure must not ack the blob away',
        );
      }
      // Node answers now — the message is recovered intact.
      final got = await orch2.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(got, hasLength(1));
      expect(got.single.data, data);
      expect(
        await sticky.fetch(me: me, authCookie: cookie),
        isEmpty,
        reason: 'acked only after the successful open',
      );
      expect(opens, 3);
    });

    test('an unresolvable sender is retried, not destroyed', () async {
      // PeerUnresolved says the sender's identity document did not resolve
      // RIGHT NOW — a cold routing table, a resolve racing our own
      // registration, a relay pinning a stale document (which cost this
      // network hours on 2026-08-17). Acking on it drops the relay's only
      // copy of a message that opens fine minutes later. Reported
      // 2026-08-18: it was classed permanent.
      var fail = true;
      var opens = 0;
      final inner = LoopbackMailboxCrypto(senderForOpen: peer);
      final flaky = _FlakyOpenCrypto(
        inner,
        onOpen: () => opens++,
        shouldFail: () => fail,
        failure: 'mailbox_open failed: PeerUnresolved',
      );
      final sticky = InMemoryMailboxRelay();
      final orch2 = MailboxOrchestrator(
        flaky,
        sticky,
        poisoned: freshRegistry(),
      );
      final data = Uint8List.fromList([9, 9, 9]);
      final blob = await inner.seal(
        recipient: me,
        appId: _appId(0xAD),
        endpointId: 7,
        data: data,
      );
      await sticky.put(
        receiver: me,
        contentId: _cid(0xAD),
        sender: peer,
        blob: blob,
      );

      // Two drains while the DHT has nothing: the blob must survive both.
      for (var i = 0; i < 2; i++) {
        expect(
          await orch2.drain(
            me: me,
            authCookie: cookie,
            ourCertVersion: 1,
            alreadyHave: never,
          ),
          isEmpty,
        );
      }
      expect(
        await sticky.fetch(me: me, authCookie: cookie),
        isNotEmpty,
        reason: 'an unresolved sender must not cost the relay its only copy',
      );

      // The document resolves; the message arrives and only now is acked.
      fail = false;
      final got = await orch2.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(got.single.data, data);
      expect(await sticky.fetch(me: me, authCookie: cookie), isEmpty);
      expect(opens, 3);
    });

    /// The cap stops the WORK, not the message.
    ///
    /// Reaching it used to fall through to the permanent path, which
    /// quarantines durably and ACKS — and the ack drops the relay's only copy.
    /// Nothing in a timeout or a `PeerUnresolved` says the blob is bad, so six
    /// drains during a DHT outage destroyed a message that would have opened
    /// fine afterwards. This test used to pin that, in its own words: "after
    /// the transient cap the blob is quarantined + acked".
    ///
    /// What the cap is actually for — a failed open costs the full
    /// cert-resolve timeout, ~20 s observed live — is still asserted below:
    /// the blob is never decrypt-attempted again.
    test(
      'opens that time out forever stop costing anything, and are not destroyed',
      () async {
        var opens = 0;
        final inner = LoopbackMailboxCrypto(senderForOpen: peer);
        final flaky = _FlakyOpenCrypto(
          inner,
          onOpen: () => opens++,
          shouldFail: () => true, // never recovers
        );
        final sticky = InMemoryMailboxRelay();
        final orch2 = MailboxOrchestrator(
          flaky,
          sticky,
          poisoned: freshRegistry(),
        );
        final blob = await inner.seal(
          recipient: me,
          appId: _appId(0xAC),
          endpointId: 7,
          data: Uint8List.fromList([1]),
        );
        await sticky.put(
          receiver: me,
          contentId: _cid(0xAC),
          sender: peer,
          blob: blob,
        );

        // Retried across drains up to the cap, then left alone.
        for (var i = 0; i < 6; i++) {
          await orch2.drain(
            me: me,
            authCookie: cookie,
            ourCertVersion: 1,
            alreadyHave: never,
          );
        }
        expect(
          await sticky.fetch(me: me, authCookie: cookie),
          isNotEmpty,
          reason:
              'the relay holds the only copy, and nothing said the blob was '
              'bad — a restart, or a network that recovers, must still get it',
        );
        final opensAtCap = opens;
        await orch2.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        );
        expect(
          opens,
          opensAtCap,
          reason:
              'past the cap the blob costs nothing: skipped without an open, '
              'which is the whole reason the cap exists',
        );
      },
    );

    /// The point of not acking: the message is still there to be had.
    ///
    /// A DHT outage longer than six drains is the case this exists for — a
    /// cold routing table after a restart, a resolve racing the node's own
    /// registration, a relay pinning a stale document (which cost this network
    /// hours on 2026-08-17). The blob was fine the whole time.
    test(
      'a blob given up on transiently still arrives once the node recovers',
      () async {
        final inner = LoopbackMailboxCrypto(senderForOpen: peer);
        var failing = true;
        final flaky = _FlakyOpenCrypto(
          inner,
          onOpen: () {},
          shouldFail: () => failing,
        );
        final sticky = InMemoryMailboxRelay();
        final registry = freshRegistry();
        final data = Uint8List.fromList([9, 9, 9]);
        final blob = await inner.seal(
          recipient: me,
          appId: _appId(0xAD),
          endpointId: 7,
          data: data,
        );
        await sticky.put(
          receiver: me,
          contentId: _cid(0xAD),
          sender: peer,
          blob: blob,
        );

        final duringOutage = MailboxOrchestrator(
          flaky,
          sticky,
          poisoned: registry,
        );
        for (var i = 0; i < 8; i++) {
          await duringOutage.drain(
            me: me,
            authCookie: cookie,
            ourCertVersion: 1,
            alreadyHave: never,
          );
        }
        expect(
          await registry.contains(_cid(0xAD)),
          isFalse,
          reason: 'a transient failure must not earn a DURABLE quarantine',
        );

        // The network comes back, and so does the app.
        failing = false;
        final afterRestart = MailboxOrchestrator(
          flaky,
          sticky,
          poisoned: registry,
        );
        final got = await afterRestart.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        );
        expect(got.single.data, data, reason: 'the message was never lost');
        expect(
          await sticky.fetch(me: me, authCookie: cookie),
          isEmpty,
          reason: 'and NOW it is acked, because it was actually delivered',
        );
      },
    );

    test(
      'quarantine is FIFO-capped so junk deposits cannot grow the registry',
      () async {
        final reg = freshRegistry();
        for (var i = 0; i < 80; i++) {
          await reg.add(_cid(i));
        }
        // Visible at once — only the write waits for the end of the pass.
        expect(await reg.contains(_cid(0)), isFalse);
        expect(await reg.contains(_cid(79)), isTrue);
        await reg.flush();
        // Oldest evicted, newest kept (cap = 64).
        final stored = settings['mailbox.poisoned.v1']!;
        expect(RegExp('"').allMatches(stored).length ~/ 2, 64);
      },
    );

    test('a pass of junk costs one container write, not one per blob', () {
      // Each write lands in the deniable container, so the write RATE is the
      // cost a junk producer controls — the FIFO cap bounds the size and says
      // nothing about how often it is rewritten. Reported 2026-08-18.
      var writes = 0;
      final reg = PoisonedBlobRegistry(
        getSetting: (k) async => settings[k],
        putSetting: (k, v) async {
          writes++;
          settings[k] = v;
        },
      );
      return Future(() async {
        for (var i = 0; i < 10; i++) {
          await reg.add(_cid(i));
        }
        expect(writes, 0, reason: 'nothing is written until the pass ends');
        await reg.flush();
        expect(writes, 1);
        await reg.flush();
        expect(writes, 1, reason: 'a flush with nothing new writes nothing');
      });
    });
  });
}

/// Open fails with the node's IPC-timeout error while [shouldFail] says so —
/// models a busy/starting runtime that doesn't answer `mailbox_open` (the
/// error TEXT carries the "timeout" discriminant the orchestrator keys on).
class _FlakyOpenCrypto implements VeilMailboxCrypto {
  _FlakyOpenCrypto(
    this._inner, {
    required this.onOpen,
    required this.shouldFail,
    this.failure =
        'mailbox_open failed: protocol error: timeout waiting for '
        'mailbox_open reply',
  });
  final VeilMailboxCrypto _inner;
  final void Function() onOpen;
  final bool Function() shouldFail;

  /// The native text an open failed with. The orchestrator reads the status
  /// discriminant out of it, so a test that wants a different transient (or a
  /// permanent failure) says so here.
  final String failure;

  @override
  Future<Uint8List> seal({
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
  }) => _inner.seal(
    recipient: recipient,
    appId: appId,
    endpointId: endpointId,
    data: data,
  );

  @override
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  }) {
    onOpen();
    if (shouldFail()) {
      throw Exception(failure);
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
  }) => _inner.seal(
    recipient: recipient,
    appId: appId,
    endpointId: endpointId,
    data: data,
  );

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

/// Opens everything except one payload byte, and for THAT one throws the
/// transient error the drain is built to wait out.
///
/// The failure names a timeout on purpose: that word is the discriminator the
/// orchestrator uses to tell "the node was busy" from "this blob is bad", and
/// the whole point of the transient class is that it says nothing about the
/// blob.
class _StallsOnOneBlob extends LoopbackMailboxCrypto {
  _StallsOnOneBlob(this.stalledByte, {super.senderForOpen});

  /// Payload byte identifying the blob that will not open yet.
  final int stalledByte;

  /// Flip to let it through, the way a DHT that has caught up would.
  bool recovered = false;

  int attempts = 0;

  @override
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  }) async {
    final opened = await super.open(blob: blob, ourCertVersion: ourCertVersion);
    if (!recovered &&
        opened.data.isNotEmpty &&
        opened.data.first == stalledByte) {
      attempts++;
      throw StateError('timeout waiting for mailbox_open reply');
    }
    return opened;
  }
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
      me: me,
      authCookie: authCookie,
      knownRelays: knownRelays,
    );
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
