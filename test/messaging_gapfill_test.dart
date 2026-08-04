import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A 1:1 fake link whose live send can be DROPPED ([drop] = true) to model a
/// lost live datagram — there is no mailbox here, so a dropped send is fully
/// lost and the ONLY way the peer recovers it is the event-log gap-fill beacon.
class _LossyTransport implements VeilTransport {
  _LossyTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _LossyTransport? peer;
  bool drop = false;
  // Drop fileChunk frames whose index is in this set (simulate selective chunk
  // loss). Count fileChunk frames actually delivered (resumable-resend assert).
  Set<int> dropChunks = {};
  int chunkSends = 0;

  /// Envelopes whose body contains any of these are eaten FOREVER — a message
  /// the sender keeps re-shipping and the receiver can never get.
  Set<String> dropIfBodyContains = {};

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    if (drop) return; // live datagram lost
    final env = WireEnvelope.decode(payload);
    if (dropIfBodyContains.any(env.body.contains)) return;
    if (env.kind == WireKind.fileChunk) {
      final frame = parseFileChunk(env.body);
      if (dropChunks.contains(frame.index)) return; // selective chunk loss
      chunkSends++;
    }
    peer?._inbound.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  /// Inject an inbound frame as if it arrived over the wire from [from] (used to
  /// craft a hand-built envelope the normal send path can't produce).
  void inject(NodeId from, Uint8List payload) => _inbound.add(
    InboundMessage(
      src: from,
      payload: payload,
      provenance: SenderProvenance.sessionPeer,
    ),
  );

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _settle() async {
  // Several event-loop turns: a gap-fill round is beacon -> re-ship -> apply,
  // each crossing the serialized inbound chain, so let the microtasks drain.
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late NodeId a, b;
  late _LossyTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _LossyTransport(a);
    tB = _LossyTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_memOpener());
    sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    mA = MessagingService(tA, sA)..start();
    mB = MessagingService(tB, sB)..start();
    // Mutual accept (no greeting, so no pre-consent intro to reason about).
    await mA.sendRequest(b, '');
    await _settle();
    await mB.acceptContact(a);
    await _settle();
  });

  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
  });

  List<Message> bodies0(List<Message> m) => m;

  test(
    'a message lost on the live path self-heals via the gap-fill beacon',
    () async {
      await mA.sendText(b, 'one');
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).map((m) => m.body),
        contains('one'),
      );

      // 'two' is lost on the wire (live drop, no mailbox) — B never sees it live.
      tA.drop = true;
      await mA.sendText(b, 'two');
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).map((m) => m.body),
        isNot(contains('two')),
        reason: 'the live datagram was dropped — B must not have it yet',
      );

      // Reconnect: B beacons its high-water (it holds A up to seq 1); A re-ships
      // every event above that — 'two' (seq 2) — over the now-live path.
      tA.drop = false;
      await mB.reconcileOnConnect();
      await _settle();

      final got = await sB.loadMessages(a.hex);
      expect(
        got.map((m) => m.body),
        contains('two'),
        reason: 'gap-fill re-shipped the missing message',
      );
      // It landed under the SENDER's (author, seq) — convergent log, no phantom gap.
      final two = got.firstWhere((m) => m.body == 'two');
      expect(two.author, a.hex);
      expect(two.seq, 2);
      final sync = await sB.conversationSync(a.hex);
      expect(sync.highWater[a.hex], 2);
      expect(sync.holes[a.hex], isNull);
    },
  );

  test(
    'an edit lost on the live path self-heals (folds under the editor seq)',
    () async {
      await mA.sendText(b, 'hello');
      await _settle();
      final id = (await sB.loadMessages(
        a.hex,
      )).firstWhere((m) => m.body == 'hello').id;

      // A edits while B cannot hear it — the edit event (seq 2) is lost.
      tA.drop = true;
      await mA.editOwnMessage(id, 'hello (edited)');
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).firstWhere((m) => m.id == id).body,
        'hello',
        reason: 'B has not heard the edit yet',
      );

      // Heal: B beacons hw=1, A re-ships the edit event at seq 2.
      tA.drop = false;
      await mB.reconcileOnConnect();
      await _settle();

      final healed = (await sB.loadMessages(
        a.hex,
      )).firstWhere((m) => m.id == id);
      expect(healed.body, 'hello (edited)');
      expect(healed.edited, isTrue);
      // The edit folded under the editor's seq (2), not a fabricated local one, so
      // both devices agree the stream is gap-free up to 2 (the phantom-hole fix).
      final sync = await sB.conversationSync(a.hex);
      expect(sync.highWater[a.hex], 2);
      expect(sync.holes[a.hex], isNull);
    },
  );

  test('a delete of a NEVER-DELIVERED message heals via a void — high-water '
      'advances, the message never resurrects', () async {
    await mA.sendText(b, 'keep'); // seq 1 — B gets it
    await _settle();

    // 'gone' (seq 2) is lost on the wire, then A unsends it before B ever saw it.
    tA.drop = true;
    await mA.sendText(b, 'gone');
    await _settle();
    final goneId = (await sA.loadMessages(
      b.hex,
    )).firstWhere((m) => m.body == 'gone').id;
    await mA.deleteForEveryone(
      goneId,
    ); // tombstones seq 2 on A (del wire dropped)
    await _settle();

    // Reconnect: B beacons hw=1; A re-ships the deleted slot as an inert void(2).
    tA.drop = false;
    await mB.reconcileOnConnect();
    await _settle();

    // B advanced its high-water past the deleted slot (no permanent stall)...
    final sync = await sB.conversationSync(a.hex);
    expect(sync.highWater[a.hex], 2);
    expect(sync.holes[a.hex], isNull);
    // ...and the deleted message never materialised on B (no resurrection).
    final bodies = (await sB.loadMessages(a.hex)).map((m) => m.body);
    expect(bodies, contains('keep'));
    expect(bodies, isNot(contains('gone')));
  });

  test(
    'a hole nobody can fill is given up on, so the tail stops re-shipping',
    () async {
      // A high-water is a claim of CONTIGUITY, so one sequence that never
      // arrives pins it forever — and the sender, reading that pinned mark,
      // re-ships the whole tail above it on every round. Measured on a live
      // pair: 316 frames and 1.4 MB per round, between two idle devices,
      // indefinitely.
      //
      // The give-up is taken by the WAITING side. The sender cannot tell "I lost
      // it" from "I deleted it for myself only", so a sender-side rule would
      // turn the second into a delete for everyone.
      await mA.sendText(b, 'keep'); // seq 1
      await _settle();

      tA.dropIfBodyContains = {'stuck'}; // eaten on every attempt, forever
      await mA.sendText(b, 'stuck'); // seq 2 — B never gets it
      await _settle();
      await mA.sendText(b, 'after'); // seq 3 — B gets it, so 2 is a HOLE
      await _settle();

      var sync = await sB.conversationSync(a.hex);
      expect(sync.highWater[a.hex], 1, reason: 'pinned below the hole');
      expect(sync.holes[a.hex], isNotEmpty);

      // Five rounds of asking: still waiting, because a hole that MIGHT still
      // arrive must not be abandoned on the first disappointment.
      for (var round = 0; round < 4; round++) {
        await mB.reconcileOnConnect();
        await _settle();
      }
      sync = await sB.conversationSync(a.hex);
      expect(
        sync.highWater[a.hex],
        1,
        reason: 'four rounds is not yet evidence that nobody can supply it',
      );

      // Keep asking until the give-up threshold.
      for (var round = 0; round < 4; round++) {
        await mB.reconcileOnConnect();
        await _settle();
      }

      sync = await sB.conversationSync(a.hex);
      expect(
        sync.highWater[a.hex],
        3,
        reason: 'stopped waiting and moved past what nobody can supply',
      );
      expect(sync.holes[a.hex], isNull);
      final bodies = (await sB.loadMessages(a.hex)).map((m) => m.body);
      expect(bodies, containsAll(['keep', 'after']));
      expect(
        bodies,
        isNot(contains('stuck')),
        reason: 'giving up must not invent the message it gave up on',
      );
    },
  );

  test('a file lost on the live path self-heals via gap-fill (filePost)', () async {
    await mA.sendText(b, 'hi'); // seq 1 — so the file is seq 2 in the stream
    await _settle();

    tA.drop = true;
    final bytes = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    await mA.sendFile(b, bytes, 'photo.bin');
    await _settle();
    expect(
      (await sB.loadMessages(a.hex)).where((m) => m.isFile),
      isEmpty,
      reason: 'the file frames were dropped — B has no file yet',
    );

    // Reconnect: B beacons hw=1; A re-ships the file (meta seq 2 + chunks).
    tA.drop = false;
    await mB.reconcileOnConnect();
    await _settle();

    final files = (await sB.loadMessages(
      a.hex,
    )).where((m) => m.isFile).toList();
    expect(files, hasLength(1), reason: 'gap-fill re-shipped the file');
    expect(files.single.seq, 2, reason: 'folded under the sender filePost seq');
    expect(
      await sB.loadFile(files.single.fileId!),
      bytes,
      reason: 'the blob bytes round-tripped',
    );
    // The file folded under the SENDER's send-time, not B's receive time — so the
    // convergent (effective_ts, author, seq) order is identical on both devices.
    final aFile = (await sA.loadMessages(b.hex)).firstWhere((m) => m.isFile);
    expect(
      files.single.timestamp,
      aFile.timestamp,
      reason: 'file display time converges to the sender send-time',
    );
    final sync = await sB.conversationSync(a.hex);
    expect(sync.highWater[a.hex], 2);
    expect(sync.holes[a.hex], isNull);
  });

  test(
    'a PARTIALLY-received file resumes — only the MISSING chunks re-send',
    () async {
      await mA.sendText(b, 'hi'); // seq 1
      await _settle();
      // ~3 chunks at 6000 B/chunk. Drop ONLY chunk index 1 on the first push, so
      // B holds chunks 0 and 2 but the transfer is incomplete.
      final bytes = Uint8List.fromList(
        List.generate(13000, (i) => (i * 7) % 256),
      );
      tA.dropChunks = {1};
      await mA.sendFile(b, bytes, 'big.bin');
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).where((m) => m.isFile),
        isEmpty,
        reason: 'one chunk dropped — transfer incomplete, no file message yet',
      );

      // Reconnect: B beacons → A probes (fileQuery) → B NACKs [1] → A re-sends ONLY
      // chunk 1 (resumable), NOT the whole blob.
      tA.dropChunks = {};
      tA.chunkSends = 0;
      await mB.reconcileOnConnect();
      await _settle();

      final files = (await sB.loadMessages(
        a.hex,
      )).where((m) => m.isFile).toList();
      expect(files, hasLength(1), reason: 'the file completed');
      expect(
        await sB.loadFile(files.single.fileId!),
        bytes,
        reason: 'blob bytes round-trip',
      );
      expect(
        tA.chunkSends,
        1,
        reason: 'resumable: only the missing chunk re-sent, not all 3',
      );
    },
  );

  test('the receive-time bound on a message stamp is ONE-SIDED and tolerates '
      'honest drift', () {
    const now = 1700000000000;
    const week = Duration(days: 7);

    // The past is never touched. A device a week offline receives a mirror of
    // last Tuesday's message and must keep last Tuesday; and a stamp in the
    // past cannot float ABOVE anything anyway — the author-monotone effective
    // ts floor in loadMessages puts it back into its author's causal place.
    expect(
      messageTsOnReceipt(now - week.inMilliseconds, now),
      now - week.inMilliseconds,
    );
    expect(messageTsOnReceipt(0, now), 0);
    expect(messageTsOnReceipt(now, now), now);

    // Honest drift is believed to the millisecond, all the way to the bound.
    // This is the whole reason the bound is a TOLERANCE and not "anything ahead
    // of my clock": ordinary traffic is stored byte-identically on every device
    // the owner has, so the convergent display order is untouched by this rule.
    expect(
      messageTsOnReceipt(now + kMessageClockSkew.inMilliseconds, now),
      now + kMessageClockSkew.inMilliseconds,
      reason: 'a sender exactly at the tolerated skew is still believed',
    );

    // One millisecond past it is not a clock reading any more, and the only
    // time the receiver actually knows is when the thing arrived.
    expect(
      messageTsOnReceipt(now + kMessageClockSkew.inMilliseconds + 1, now),
      now,
    );
    expect(
      messageTsOnReceipt(now + const Duration(days: 365).inMilliseconds, now),
      now,
    );
  });

  test('a wire message stamped past the tolerated skew is stored at the moment '
      'it ARRIVED — once, and a re-delivery never restamps it', () async {
    // A private receiver with a held clock: this asserts an exact stored value,
    // so it must not race DateTime.now.
    var wall = DateTime.utc(2026, 8, 3, 12);
    final arrivedAt = wall.millisecondsSinceEpoch;
    final tC = _LossyTransport(b);
    final sC = HiddenVolumeStorage(_memOpener());
    await sC.open(password: 'c', createIfMissing: true);
    final mC = MessagingService(tC, sC, now: () => wall)..start();
    addTearDown(mC.dispose);
    await sC.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    Future<int> tsOf(String id) async => (await sC.loadMessages(
      a.hex,
    )).firstWhere((m) => m.id == id).timestamp.millisecondsSinceEpoch;

    // A sender whose clock is honestly a few minutes fast is stored VERBATIM:
    // the (effective_ts, author, seq) order stays identical across devices for
    // every message a real clock can produce.
    final honest = arrivedAt + kMessageClockSkew.inMilliseconds - 1000;
    tC.inject(
      a,
      WireEnvelope.message(
        'nearly now',
        id: 'skew-1',
        sentAtMs: honest,
        seq: 1,
      ).encode(),
    );
    await _settle();
    expect(
      await tsOf('skew-1'),
      honest,
      reason: 'inside the tolerance the sender is believed exactly',
    );

    // A stamp no clock produces is replaced by the receive time. Left alone it
    // would own the bottom of this chat, the conversation-list preview and the
    // top of the chat list until 2100.
    const year2100 = 4102444800000;
    tC.inject(
      a,
      WireEnvelope.message(
        'from the future',
        id: 'fut-1',
        sentAtMs: year2100,
        seq: 2,
      ).encode(),
    );
    await _settle();
    expect(
      await tsOf('fut-1'),
      arrivedAt,
      reason: 'not a time — stored as the moment of receipt',
    );

    // The second-order harm is gone with it: markRead takes the conversation's
    // NEWEST timestamp as the read watermark and setReadMarker only ever moves
    // forward, so one 2100-stamped row used to retire this conversation's
    // unread badge permanently.
    await sC.markRead(a.hex);
    expect(
      await sC.readMarker(a.hex),
      lessThanOrEqualTo(arrivedAt + kMessageClockSkew.inMilliseconds),
    );

    // ONCE, at receipt. The sender's outbox re-sends un-acked frames and the
    // gap-fill beacon re-ships whole ranges, so this exact frame comes back —
    // hours later, against a clock that has moved. The stored stamp must not
    // follow it, or the row climbs back to the top every time it is re-offered.
    wall = wall.add(const Duration(hours: 3));
    tC.inject(
      a,
      WireEnvelope.message(
        'from the future',
        id: 'fut-1',
        sentAtMs: year2100,
        seq: 2,
      ).encode(),
    );
    await _settle();
    expect(
      await tsOf('fut-1'),
      arrivedAt,
      reason: 'stamped once on arrival; a re-delivery must not restamp it',
    );
    // ...and re-reading the log is a pure re-fold, never a re-stamp.
    expect(await tsOf('fut-1'), arrivedAt);
  });

  test('a peer that LOST its message data re-syncs from zero on reconnect '
      '(Case-A wipe recovery via the beacon)', () async {
    await mA.sendText(b, 'm1');
    await mA.sendText(b, 'm2');
    await mA.sendText(b, 'm3');
    await _settle();
    expect((await sB.loadMessages(a.hex)).length, greaterThanOrEqualTo(3));

    // B reinstalls: a fresh, EMPTY space that re-adds A as an accepted contact
    // (the relationship survives a wipe; only the message log is gone). A still
    // holds B accepted with the full log.
    await mB.dispose();
    final tB2 = _LossyTransport(b);
    tA.peer = tB2;
    tB2.peer = tA;
    final sB2 = HiddenVolumeStorage(_memOpener());
    await sB2.open(password: 'b2', createIfMissing: true);
    await sB2.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    final mB2 = MessagingService(tB2, sB2)..start();
    addTearDown(mB2.dispose);

    // Reconnect: B2 beacons hw[A]={} (it holds nothing) → A re-ships everything.
    await mB2.reconcileOnConnect();
    await _settle();

    final recovered = (await sB2.loadMessages(
      a.hex,
    )).map((m) => m.body).toSet();
    expect(
      recovered,
      containsAll(['m1', 'm2', 'm3']),
      reason: 'the wiped peer recovered the whole conversation from the log',
    );
  });

  test(
    'gap-fill is bidirectional from a single reconnect (beacon-back)',
    () async {
      // Both sides send while the OTHER direction is dropped, so each is missing
      // one of the other's messages; a single reconnect must heal both ways.
      await mA.sendText(b, 'a-live');
      await mB.sendText(a, 'b-live');
      await _settle();

      tA.drop = true;
      tB.drop = true;
      await mA.sendText(b, 'a-lost');
      await mB.sendText(a, 'b-lost');
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).map((m) => m.body),
        isNot(contains('a-lost')),
      );
      expect(
        (await sA.loadMessages(b.hex)).map((m) => m.body),
        isNot(contains('b-lost')),
      );

      // One side reconnecting beacons; the handler beacons back, so BOTH heal.
      tA.drop = false;
      tB.drop = false;
      await mB.reconcileOnConnect();
      await _settle();

      expect(
        bodies0(await sB.loadMessages(a.hex)).map((m) => m.body),
        contains('a-lost'),
        reason: "B recovered A's lost message",
      );
      expect(
        bodies0(await sA.loadMessages(b.hex)).map((m) => m.body),
        contains('b-lost'),
        reason: "A recovered B's lost message via the beacon-back",
      );
    },
  );

  test('peers whose early history was erased at the source CONVERGE via the '
      'beacon floor instead of an endless holes/reship ping-pong', () async {
    await mA.sendText(b, 'old-1');
    await mA.sendText(b, 'old-2');
    await mB.sendText(a, 'old-b1');
    await _settle();

    // Wholesale log erase on BOTH ends while the per-author seq counters keep
    // advancing (the bench /purge_files state — the same shape as any lost
    // early history). The erased prefix no longer exists at its AUTHOR, so no
    // re-request can ever fill it.
    await sA.purgeMessageLog();
    await sB.purgeMessageLog();

    await mA.sendText(b, 'new-a'); // A's stream: rows {3} everywhere
    await _settle();

    // Without the floor, B saw A:{3} as hw=0 + hole [1..2] and every beacon
    // round re-triggered the same futile reship of 'new-a', forever.
    await mB.reconcileOnConnect();
    await _settle();

    final syncB = await sB.conversationSync(a.hex);
    expect(
      syncB.highWater[a.hex],
      3,
      reason:
          "A's beacon floor closes the erased prefix — hw reaches the "
          'live message',
    );
    expect(
      syncB.holes,
      isEmpty,
      reason: 'nothing left to re-request: the ping-pong driver is gone',
    );

    final syncA = await sA.conversationSync(b.hex);
    expect(
      syncA.holes,
      isEmpty,
      reason: "the beacon-back carries B's floor so A converges too",
    );

    // The live message itself is intact.
    expect(
      (await sB.loadMessages(a.hex)).map((m) => m.body),
      contains('new-a'),
    );
  });

  test('a declared floor only silences the SENDER-OWN stream — a forged floor '
      'for another author is ignored', () async {
    await mA.sendText(b, 'a-1');
    await _settle();

    // Inject into A a beacon from B declaring a floor for A's OWN stream. The
    // handler only accepts fl[src.hex] (an author may void only its own
    // history), so A's stream state must not move.
    tA.inject(
      b,
      WireEnvelope.sync('{"hw":{},"fl":{"${a.hex}":99},"ep":1}').encode(),
    );
    await _settle();

    final syncA = await sA.conversationSync(b.hex);
    // Had the forged floor been applied, A's own hw would have jumped to 99.
    expect(
      syncA.highWater[a.hex] ?? 0,
      lessThan(99),
      reason: "a peer must not be able to void another author's stream",
    );
  });

  // A sequence number is a SLOT — which position in whose stream — and every
  // door that admits one from the wire takes the same bound, in one place. Out
  // of range the frame goes; the value is never pulled into range, because two
  // different events folded onto one slot lose one of them and make the
  // already-applied checks answer yes for something never seen.
  group('a sequence number off the wire is bounded, and out of range the frame '
      'is dropped rather than clamped', () {
    test('a void slot naming a seq past the maximum records nothing', () async {
      await mA.sendText(b, 'one');
      await _settle();
      expect(
        (await sB.conversationSync(a.hex)).highWater[a.hex],
        1,
        reason: 'sanity: the honest slot 1 is held',
      );

      // ~60 bytes from the ACCEPTED contact, and no visible message at all.
      tB.inject(a, const WireEnvelope.voidSeq(kMaxWireSeq + 1).encode());
      await _settle();

      final sync = await sB.conversationSync(a.hex);
      expect(sync.highWater[a.hex], 1, reason: 'the slot was never recorded');
      expect(
        sync.holes[a.hex],
        isNull,
        reason: 'and no span was opened up to the number it named',
      );

      // The bound is on the value, not on the sender: A is still a contact in
      // good standing and its next honest message lands as usual.
      await mA.sendText(b, 'two');
      await _settle();
      expect(
        (await sB.loadMessages(a.hex)).map((m) => m.body),
        contains('two'),
      );
    });

    // The pair with the test above: that one names one PAST the maximum and
    // must record nothing, this one names the maximum ITSELF and must record
    // it. Deliberately separate fixtures — asserting both in one conversation
    // proves nothing, because a slot at the maximum and a slot just above it
    // are adjacent, so the hole shape is identical whether the second lands or
    // not.
    test(
      'the bound is inclusive: the maximum itself is a usable slot',
      () async {
        await mA.sendText(b, 'one');
        await _settle();

        tB.inject(a, const WireEnvelope.voidSeq(kMaxWireSeq).encode());
        await _settle();
        expect(
          (await sB.conversationSync(a.hex)).holes[a.hex],
          [(2, kMaxWireSeq - 1)],
          reason: 'the maximum is a real slot, not one past the end',
        );
      },
    );

    test('a message carrying an out-of-range seq does not arrive at some other '
        'slot instead — it does not arrive at all', () async {
      await mA.sendText(b, 'one');
      await _settle();

      tB.inject(
        a,
        const WireEnvelope.message(
          'poison',
          id: 'p1',
          seq: kMaxWireSeq + 1,
        ).encode(),
      );
      await _settle();

      // Clamping would have stored this at the largest accepted slot, where it
      // would sit in the chat and occupy a slot its author never used.
      expect(
        (await sB.loadMessages(a.hex)).map((m) => m.body),
        isNot(contains('poison')),
      );
      expect(
        (await sB.conversationSync(a.hex)).highWater[a.hex],
        1,
        reason: 'no slot of the peer stream moved',
      );
    });

    test('a clear whose watermark names a seq past the maximum is dropped, and '
        'the history it aimed at stays', () async {
      await mA.sendText(b, 'keep me');
      await _settle();
      expect((await sB.loadMessages(a.hex)).length, 1);

      tB.inject(
        a,
        WireEnvelope.clear(
          jsonEncode({a.hex: kMaxWireSeq + 1}),
          seq: 5,
        ).encode(),
      );
      await _settle();

      expect(
        (await sB.loadMessages(a.hex)).map((m) => m.body),
        contains('keep me'),
      );
    });

    // The paired floor tests: the first proves an injected beacon really is
    // acted on here (the handler throttles, so without it the second could
    // pass while doing nothing at all).
    test('an in-range beacon floor is applied', () async {
      await mA.sendText(b, 'a-1');
      await _settle();

      tB.inject(
        a,
        WireEnvelope.sync('{"hw":{},"fl":{"${a.hex}":3},"ep":1}').encode(),
      );
      await _settle();

      expect(
        (await sB.conversationSync(a.hex)).highWater[a.hex],
        3,
        reason: "the peer's declared prefix closed over its own stream",
      );
    });

    test('a beacon floor past the maximum is ignored, so gap-fill for that '
        'peer survives', () async {
      await mA.sendText(b, 'a-1');
      await _settle();

      tB.inject(
        a,
        WireEnvelope.sync(
          '{"hw":{},"fl":{"${a.hex}":${kMaxWireSeq + 1}},"ep":1}',
        ).encode(),
      );
      await _settle();

      // A floor is monotonic and permanent: applied once, every later message
      // from this peer sits below a mark claiming it no longer exists at the
      // source, and nothing can ever be re-requested in this chat again.
      expect(
        (await sB.conversationSync(a.hex)).highWater[a.hex],
        1,
        reason:
            'a prefix nobody could have reached must not retire the '
            'stream',
      );
    });
  });
}
