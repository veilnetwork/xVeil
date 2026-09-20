import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/state/mailbox_orchestrator.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));
Uint8List _cid(int s) => Uint8List.fromList(List.filled(32, s));
Uint8List _appId(int s) => Uint8List.fromList(List.filled(32, s));
String _hexOf(Uint8List b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

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

  test('drain skips a corrupt blob without wedging the inbox, and without '
      'acking it', () async {
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
    // The good one is delivered and acked away. The corrupt one is dropped
    // and LEFT: an ack names a content id and nothing else, so the relay
    // cannot tell the copy that failed from any other under that id, and a
    // body that would not open is never a reason to delete anything
    // (report27 X35). This device stops re-opening it through the quarantine
    // instead; the relay's TTL clears the copy.
    expect(drained, hasLength(1));
    expect(drained.single.data, Uint8List.fromList([42]));
    final left = await relay.fetch(me: me, authCookie: cookie);
    expect(
      left.map((b) => b.contentId),
      [_cid(0xBA)],
      reason:
          'the good blob must be acked away and the corrupt one must not be',
    );
  });

  /// A forged body under a real message id must not destroy the real one.
  ///
  /// The content id is the message uuid: it names the message, not the bytes.
  /// A replica of the receiver's own set can therefore answer with a genuine
  /// id and a substituted body, and the drain used to union by that id alone —
  /// first copy winning — then quarantine the id on the first failed open and
  /// ACK every replica, which deletes the honest copies for good (report22
  /// XV-MBX1). One bad replica out of N is exactly the failure replication
  /// exists to survive.
  test(
    'a forged body under a real id does not delete the honest one',
    () async {
      final data = Uint8List.fromList([7, 7, 7]);
      final cid = _cid(0xD1);
      // The malicious replica answers FIRST — that is the attacker's whole
      // advantage, and a test that puts the honest body first proves nothing:
      // it passes with the fix removed.
      await relay.put(
        receiver: me,
        contentId: cid,
        sender: peer,
        blob: Uint8List.fromList([0, 1, 2]), // < 36 bytes -> open throws
      );
      // The honest deposit, under the same id.
      await orch.stash(
        me: peer,
        recipient: me,
        appId: _appId(5),
        endpointId: 11,
        data: data,
        contentId: cid,
      );
      final pending = await relay.fetch(me: me, authCookie: cookie);
      expect(pending, hasLength(2), reason: 'premise: two bodies, one id');

      final drained = await orch.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(
        drained,
        hasLength(1),
        reason: 'the forged body under a genuine id destroyed the real message',
      );
      expect(drained.single.data, data, reason: 'and it is the honest body');
    },
  );

  /// The honest copy survives a body that would not open.
  ///
  /// A message large enough to be ANNOUNCED is fetched in slices, and the
  /// collector returns the FIRST body it can assemble and stops — so the
  /// batch holds one variant, the "another variant is still to try" guard sees
  /// none, and the id was acked. An ack names a content id and nothing else,
  /// so the relay cannot tell the copy that failed from any other under that
  /// id: one compromised relay among those in use could delete a message that
  /// would have opened (report27 X35).
  test('a failed open never deletes a copy nobody looked at', () async {
    final cid = _cid(0xE7);
    // One body, undecryptable. In the sliced case this is all the batch has.
    await relay.put(
      receiver: me,
      contentId: cid,
      sender: peer,
      blob: Uint8List.fromList([0, 1, 2]),
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

    // Whatever is filed under that id is still at the relay. In production the
    // copy this device never saw is the honest one, and it is the copy an ack
    // would have taken.
    expect(
      (await relay.fetch(
        me: me,
        authCookie: cookie,
      )).map((b) => b.contentId).where((id) => id[0] == cid[0]),
      isNotEmpty,
      reason:
          'the drain acked an id it could only fail to open, which deletes '
          'every replica under it — including one nothing has verified',
    );
  });

  /// And a content id is given up only when NOTHING filed under it opened —
  /// given up LOCALLY, by quarantine, never by deleting the relay's copies.
  ///
  /// The ack used to go out here. It names a content id, so it takes every
  /// replica: for a message small enough to arrive whole the other bodies in
  /// the batch are tried first, but a message large enough to be announced and
  /// fetched in slices returns ONE assembled body, and the honest copy on
  /// another relay is deleted without anything having looked at it
  /// (report27 X35).
  test('an id whose every body fails is quarantined and not acked', () async {
    final cid = _cid(0xD2);
    for (final junk in [
      Uint8List.fromList([0, 1, 2]),
      Uint8List.fromList([3, 4, 5]),
    ]) {
      await relay.put(receiver: me, contentId: cid, sender: peer, blob: junk);
    }
    final drained = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: never,
    );
    expect(drained, isEmpty);
    expect(
      await relay.fetch(me: me, authCookie: cookie),
      isNotEmpty,
      reason:
          'the drain deleted every copy under an id it merely could not open '
          '— including any honest one it never looked at',
    );

    // What stops the re-open loop is the quarantine, not the ack: a second
    // drain returns nothing and does not pay for the opens again.
    final again = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: never,
    );
    expect(again, isEmpty);
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

    test('the relay is TOLD, so the tail is not stuck behind it', () async {
      // The back-off bounds how long the stall lasts. Telling the relay
      // removes it: a relay new enough to read the hint passes over the head
      // and serves what is behind it (report14 X14-M4).
      //
      // Proved by COMPARISON, because "the tail arrived" alone would also be
      // true of a fixture that never stalled: the same sequence against a
      // relay that ignores the hint must yield nothing.
      Future<List<int>> drainAll(VeilMailboxRelay relay, DateTime at) async {
        final crypto = _StallsOnOneBlob(0xD1, senderForOpen: peer);
        final orch = MailboxOrchestrator(crypto, relay)..now = () => at;
        for (final byte in [0xD1, 0xD2, 0xD3]) {
          await orch.stash(
            me: peer,
            recipient: me,
            appId: _appId(1),
            endpointId: 2,
            data: Uint8List.fromList([byte]),
            contentId: _cid(byte),
          );
        }
        final got = <int>[];
        for (var i = 0; i < 10; i++) {
          final drained = await orch.drain(
            me: me,
            authCookie: cookie,
            ourCertVersion: 1,
            alreadyHave: never,
          );
          got.addAll(drained.map((d) => d.data.single));
        }
        return got;
      }

      // The clock never moves in either run: no back-off is waited out.
      final at = DateTime.utc(2026, 8, 25, 12);

      final deaf = _OneBlobPerFetchRelay();
      expect(
        await drainAll(deaf, at),
        isEmpty,
        reason:
            'a relay that ignores the hint keeps serving the blob we '
            'cannot use, and nothing behind it is reachable — this is the '
            'finding',
      );

      final listening = _SkipHonouringRelay();
      expect(
        await drainAll(listening, at),
        containsAll(<int>[0xD2, 0xD3]),
        reason:
            'once the relay is told to pass over the head, the queue '
            'behind it moves without waiting for anything',
      );
      expect(
        listening.asked,
        isNotEmpty,
        reason:
            'and it was told: an empty hint would make this test about '
            'the fixture',
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

    test('a junk backlog is fully quarantined in one drain — it must '
        'not look like a live producer of one fresh cid per drain', () async {
      var opens = 0;
      // A relay that honours `skip`, which is what the real one does
      // (`Mailbox::fetch_skipping`). The ack used to move this queue along;
      // it cannot any more, because an ack names a content id and would take
      // every replica under it (report27 X35). The hint does the same job
      // without destroying anything.
      final budgeted = _SkipHonouringRelay();
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
        isNotEmpty,
        reason:
            'the drain deleted copies it merely could not open — an ack names '
            'a content id, so it takes every replica under it',
      );
      expect(
        budgeted.asked,
        hasLength(4),
        reason:
            'every junk id must be in the hint, or the queue behind it is '
            'unreachable for the relay TTL',
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
        onMessage: (m) async {
          handedUp = m;
          fetchesWhenHandedUp = sticky.fetchCalls;
          return true;
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

    /// The half report27 X35 left behind.
    ///
    /// The ack at the point of failure went; two ack sites keyed on the
    /// QUARANTINE stayed. Inside one session they are unreachable — the id is
    /// in the skip hint, so the relay does not serve it. But `_openFailedOnce`
    /// is in RAM, and it was the only thing feeding that hint: after a
    /// relaunch the hint was empty, the relay served the blob again, and the
    /// branch that met it acked the id away. An ack names a content id and
    /// nothing else, so that takes every replica under it — the honest copy on
    /// another relay included. The deletion X35 removed, one restart later.
    test('a relaunch does not ack away the id the quarantine holds', () async {
      // Deaf to the skip hint, the way a relay too old to read the field is —
      // which is what puts the drain in front of the quarantine branch at all.
      final deafRelay = _OneBlobPerFetchRelay();
      await deafRelay.put(
        receiver: me,
        contentId: _cid(0xF1),
        sender: peer,
        blob: Uint8List.fromList([0, 1, 2]), // undecryptable forever
      );

      final before = MailboxOrchestrator(
        LoopbackMailboxCrypto(senderForOpen: peer),
        deafRelay,
        poisoned: freshRegistry(),
      );
      expect(
        await before.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        ),
        isEmpty,
      );
      expect(
        await deafRelay.fetch(me: me, authCookie: cookie),
        isNotEmpty,
        reason: 'a failed open must not delete anything',
      );
      expect(
        await freshRegistry().contains(_cid(0xF1)),
        isTrue,
        reason: 'the durable quarantine is what replaced the ack',
      );

      // The app restarts: the in-RAM tier is gone, the registry is not.
      final after = MailboxOrchestrator(
        LoopbackMailboxCrypto(senderForOpen: peer),
        deafRelay,
        poisoned: freshRegistry(),
      );
      await after.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(
        await deafRelay.fetch(me: me, authCookie: cookie),
        isNotEmpty,
        reason:
            'the relaunch acked an id it never re-opened, and an ack takes '
            'every replica under that id — including one nothing looked at',
      );
    });

    /// And on a relay new enough to read the hint, a fresh session names the
    /// quarantine on its FIRST fetch — so the relay does not spend a reply
    /// slot serving a blob both sides already know will not open.
    ///
    /// The cumulative record cannot answer this: the durable branch below puts
    /// the id into the in-RAM tier when it meets it, so a LATER fetch names it
    /// either way. What the durable registry buys is the FIRST one — which,
    /// with a relay serving oldest-first under a reply budget, is the round
    /// everything behind the junk is waiting for (report14 X14-M4).
    test(
      'a fresh session names the durable quarantine on its FIRST fetch',
      () async {
        final relay = _SkipHonouringRelay();
        // Oldest first: the junk is the head of the queue, the real message is
        // behind it.
        await relay.put(
          receiver: me,
          contentId: _cid(0xF2),
          sender: peer,
          blob: Uint8List.fromList([0, 1, 2]), // undecryptable forever
        );
        final wanted = Uint8List.fromList([7, 7, 7]);
        final before = MailboxOrchestrator(
          LoopbackMailboxCrypto(senderForOpen: peer),
          relay,
          poisoned: freshRegistry(),
        );
        await before.stash(
          me: peer,
          recipient: me,
          appId: _appId(0xF3),
          endpointId: 4,
          data: wanted,
          contentId: _cid(0xF3),
        );
        // Session one meets the junk, quarantines it, and delivers the message
        // behind it.
        expect(
          (await before.drain(
            me: me,
            authCookie: cookie,
            ourCertVersion: 1,
            alreadyHave: never,
          )).single.data,
          wanted,
        );

        // A second message arrives while the app is closed.
        final later = Uint8List.fromList([8, 8, 8]);
        await before.stash(
          me: peer,
          recipient: me,
          appId: _appId(0xF4),
          endpointId: 5,
          data: later,
          contentId: _cid(0xF4),
        );

        // The app restarts. The in-RAM tier is empty; the registry is not.
        var opens = 0;
        final counting = _CountingOpenCrypto(
          LoopbackMailboxCrypto(senderForOpen: peer),
          onOpen: () => opens++,
        );
        final after = MailboxOrchestrator(
          counting,
          relay,
          poisoned: freshRegistry(),
        );
        relay.asksPerFetch.clear();
        final got = await after.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
        );

        expect(
          relay.asksPerFetch.first,
          contains(_hexOf(_cid(0xF2))),
          reason:
              'the FIRST fetch of a session must name the durable quarantine — '
              'the in-RAM tier that used to fill this hint is empty here, so '
              'without the registry the relay serves the junk head again',
        );
        expect(
          got.single.data,
          later,
          reason: 'and the message behind the junk arrives',
        );
        expect(
          opens,
          1,
          reason:
              'exactly one open: the real message. The quarantined head was '
              'passed over by the relay, not re-opened here',
        );
        expect(
          await relay.fetch(me: me, authCookie: cookie),
          isNotEmpty,
          reason: 'and the junk is still the relay\'s to keep — never acked',
        );
      },
    );

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
        // Oldest evicted, newest kept — and the whole list has to FIT: the
        // container refuses a settings value over 2048 bytes, and a cap of 64
        // hex ids produced ~4.3 KB that was never persisted at all
        // (report27 X36).
        final stored = settings['mailbox.poisoned.v1']!;
        expect(RegExp('"').allMatches(stored).length ~/ 2, 30);
        expect(
          utf8.encode(stored).length,
          lessThanOrEqualTo(2048),
          reason: 'this value is refused by the container, so nothing persists',
        );
      },
    );

    test('a flush that could not land is tried again', () async {
      // Clearing the dirty mark before the write meant one transient failure
      // cost every later flush in the session: nothing was dirty any more, so
      // nothing was written (report27 X36).
      var allow = false;
      var writes = 0;
      final reg = PoisonedBlobRegistry(
        getSetting: (k) async => settings[k],
        putSetting: (k, v) async {
          if (!allow) throw StateError('the container refused this write');
          writes++;
          settings[k] = v;
        },
      );
      await reg.add(_cid(1));
      await reg.flush();
      expect(writes, 0);

      allow = true;
      await reg.flush();
      expect(writes, 1, reason: 'the pass that failed was never retried');
    });

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

  /// A DEVICE THAT DROPPED THE MESSAGE MUST NOT DELETE IT FOR ITS SIBLINGS.
  ///
  /// An ack names a content id and nothing else, so the relay removes every
  /// replica under it — including the copies the sender deposited for this
  /// identity's other devices. Measured live (F54): a freshly linked device did
  /// not yet know the contact, fetched the message, dropped it at its consent
  /// gate, acked it away, and the device that HAD accepted the contact then
  /// found an empty mailbox. The message reached neither.
  group('a refused message is not acked away', () {
    Future<void> stashOne(Uint8List cid) => orch.stash(
      me: peer,
      recipient: me,
      appId: _appId(0xAA),
      endpointId: 9,
      data: Uint8List.fromList([1, 2, 3]),
      contentId: cid,
    );

    test(
      'refused → the blob stays at the relay for a sibling to fetch',
      () async {
        await stashOne(_cid(0xD1));
        final drained = await orch.drain(
          me: me,
          authCookie: cookie,
          ourCertVersion: 1,
          alreadyHave: never,
          onMessage: (_) async => false, // this device declined it
        );
        expect(
          drained,
          isEmpty,
          reason: 'a message this device refused is not mail it recovered',
        );
        expect(
          await relay.fetch(me: me, authCookie: cookie),
          hasLength(1),
          reason:
              'the relay must still hold the copy our other devices need; '
              'acking it would delete every replica under that content id',
        );
      },
    );

    /// CONTROL. Same blob, same drain, the one difference being the answer —
    /// otherwise the guard above would also pass on a drain that acks nothing
    /// at all.
    test('taken → the blob IS acked away, exactly as before', () async {
      await stashOne(_cid(0xD2));
      final drained = await orch.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
        onMessage: (_) async => true,
      );
      expect(drained, hasLength(1));
      expect(
        await relay.fetch(me: me, authCookie: cookie),
        isEmpty,
        reason: 'a message this device took is the relay\'s to forget',
      );
    });

    /// CONTROL. A caller that asks no question refuses nothing — every
    /// existing caller and every other test in this file relies on it.
    test('no onMessage at all → acked, as it always was', () async {
      await stashOne(_cid(0xD3));
      await orch.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
      );
      expect(await relay.fetch(me: me, authCookie: cookie), isEmpty);
    });

    /// Not acking is the point; re-fetching it on every tick is the price, and
    /// the relay fills its reply oldest-first — so a refused blob left at the
    /// head would starve everything queued behind it. It has to be named in the
    /// skip hint while its back-off lasts.
    test('and the relay is told to pass over it on the next fetch', () async {
      final skipRelay = _SkipHonouringRelay();
      final o = MailboxOrchestrator(
        LoopbackMailboxCrypto(senderForOpen: peer),
        skipRelay,
      );
      await o.stash(
        me: peer,
        recipient: me,
        appId: _appId(0xAA),
        endpointId: 9,
        data: Uint8List.fromList([1, 2, 3]),
        contentId: _cid(0xD4),
      );
      await o.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
        onMessage: (_) async => false,
      );
      final before = skipRelay.asksPerFetch.length;
      await o.drain(
        me: me,
        authCookie: cookie,
        ourCertVersion: 1,
        alreadyHave: never,
        onMessage: (_) async => false,
      );
      expect(
        skipRelay.asksPerFetch.length,
        greaterThan(before),
        reason: 'the second drain must have fetched at all',
      );
      expect(
        skipRelay.asksPerFetch[before],
        contains(_hexOf(_cid(0xD4))),
        reason:
            'the refused id must be in the hint from the FIRST fetch of the '
            'next drain, not learned again the expensive way',
      );
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

/// A one-blob relay that HONOURS the skip hint, the way a relay new enough to
/// read the field does.
///
/// The skip list is what makes the difference visible: without it the head of
/// the queue is served on every fetch and nothing behind it is reachable
/// (report14 X14-M4).
class _SkipHonouringRelay extends InMemoryMailboxRelay {
  /// Everything the caller has asked to be passed over, across all fetches.
  final asked = <String>{};

  /// And what each fetch asked, in order. The cumulative set above cannot tell
  /// "the hint carried it from the first fetch" from "a later round learned it
  /// the expensive way", which is the whole question for a fresh session.
  final asksPerFetch = <Set<String>>[];

  @override
  Future<List<StoredMailboxBlob>> fetch({
    required NodeId me,
    required Uint8List authCookie,
    List<NodeId> knownRelays = const [],
    List<Uint8List> skip = const [],
  }) async {
    asksPerFetch.add({for (final s in skip) _hex(s)});
    for (final s in skip) {
      asked.add(_hex(s));
    }
    final all = await super.fetch(
      me: me,
      authCookie: authCookie,
      knownRelays: knownRelays,
    );
    final servable = all
        .where((b) => !skip.any((s) => _hex(s) == _hex(b.contentId)))
        .toList();
    return servable.isEmpty ? const [] : [servable.first];
  }

  static String _hex(Uint8List b) =>
      [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
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
    List<Uint8List> skip = const [],
  }) async {
    fetchCalls++;
    // DEAF TO THE HINT on purpose: this models a relay that ignores `skip`,
    // which is what the stall tests above are about. The listening
    // counterpart is `_SkipHonouringRelay`.
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
