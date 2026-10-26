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

// A chunked group snapshot (an inline group image overflows a single
// groupEntry frame past the auth_deliver 6144 cap): the sender splits the
// bundle into groupEntryChunk frames and the receiver reassembles them by
// transferId, then ingests the joined bundle exactly like a whole snapshot.

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final sent = <Uint8List>[];
  _Link? peer;
  int? passLimit;
  final destinations = <NodeId>[];

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
    sent.add(Uint8List.fromList(payload));
    destinations.add(dst);
    final p = peer;
    if (p == null ||
        p._me != dst ||
        (passLimit != null && sent.length > passLimit!)) {
      return;
    }
    p._inbound.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  void inject(
    NodeId from,
    Uint8List payload, {
    NodeId? device,
    SenderProvenance provenance = SenderProvenance.sessionPeer,
  }) => _inbound.add(
    InboundMessage(
      src: from,
      srcDevice: device,
      payload: payload,
      provenance: provenance,
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
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

/// Split a bundle exactly like MessagingService.sendGroupSnapshot, returning the
/// encoded (frame-id stamped) chunk frames.
List<Uint8List> _chunkFrames(String bundle, String tid) {
  final bytes = Uint8List.fromList(utf8.encode(bundle));
  const chunk = 4000;
  final count = (bytes.length + chunk - 1) ~/ chunk;
  return [
    for (var i = 0; i < count; i++)
      groupEntryChunkEnvelope(
        transferId: tid,
        index: i,
        count: count,
        data: Uint8List.sublistView(
          bytes,
          i * chunk,
          (i + 1) * chunk < bytes.length ? (i + 1) * chunk : bytes.length,
        ),
      ).withFrameId('grpc:$tid:$i').encode(),
  ];
}

List<Uint8List> _documentChunkFrames(String frame, String tid) {
  final bytes = Uint8List.fromList(utf8.encode(frame));
  const chunk = 1800;
  final count = (bytes.length + chunk - 1) ~/ chunk;
  return [
    for (var i = 0; i < count; i++)
      cloudDocumentChunkEnvelope(
        transferId: tid,
        index: i,
        count: count,
        data: Uint8List.sublistView(
          bytes,
          i * chunk,
          (i + 1) * chunk < bytes.length ? (i + 1) * chunk : bytes.length,
        ),
      ).withFrameId('docc:$tid:$i').encode(),
  ];
}

/// Two DIFFERENT snapshot bundles whose Dart `String.hashCode` collides in the
/// low 31 bits — the exact value the durable frame id used to be built from.
///
/// Found by search rather than hard-coded: `String.hashCode` is not a
/// cross-version constant, and a stale literal pair would quietly stop testing
/// anything. 31 bits is small enough that this costs milliseconds, which is the
/// whole point of the finding (audit XV-11).
({String a, String b}) _hashCodeCollision() {
  final seen = <int, String>{};
  for (var i = 0; i < 400000; i++) {
    final candidate = '{"m":{"n":"$i"}}';
    final h = candidate.hashCode & 0x7fffffff;
    final previous = seen[h];
    if (previous != null && previous != candidate) {
      return (a: previous, b: candidate);
    }
    seen[h] = candidate;
  }
  throw StateError('no 31-bit String.hashCode collision in 400k candidates');
}

void main() {
  late NodeId a, b;
  late _Link tB;
  late HiddenVolumeStorage sB;
  late MessagingService mB;
  late String bundle; // > 4000 bytes → several chunks

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tB = _Link(b);
    sB = HiddenVolumeStorage(_memOpener());
    await sB.open(password: 'b', createIfMissing: true);
    mB = MessagingService(tB, sB)..start();
    addTearDown(mB.dispose);
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    bundle = jsonEncode({
      'm': {'name': 'Pics'},
      'g': [
        {'body': 'y' * 12000}, // forces 3+ chunks
      ],
    });
  });

  test(
    'chunks reassemble and fire onGroupEntry ONCE with the exact bundle',
    () async {
      NodeId? gotPeer;
      String? gotJson;
      var calls = 0;
      mB.onGroupEntry = (peer, json) {
        gotPeer = peer;
        gotJson = json;
        calls++;
        return true;
      };
      final frames = _chunkFrames(bundle, 'grp:z:1');
      expect(frames.length, greaterThan(1), reason: 'must actually split');
      for (final fr in frames) {
        expect(
          fr.length,
          lessThanOrEqualTo(6144),
          reason: 'each chunk must fit under the auth_deliver cap',
        );
        tB.inject(a, fr);
        await _settle();
      }
      expect(calls, 1);
      expect(gotPeer, a);
      expect(gotJson, bundle);

      // A re-driven chunk (mailbox re-delivery / restart) is deduped: no re-fire.
      tB.inject(a, frames.first);
      await _settle();
      expect(
        calls,
        1,
        reason: 'committed group receipts dedup the re-driven chunk',
      );
    },
  );

  test(
    'NON-contact sender: stranger routing + chunk admission (brick 5)',
    () async {
      final stranger = _id(9); // no contact record on B
      var acceptedCalls = 0, strangerCalls = 0;
      String? viaStranger;
      mB.onGroupEntry = (_, _) {
        acceptedCalls++;
        return true;
      };
      mB.onGroupEntryFromStranger = (peer, json) {
        viaStranger = json;
        strangerCalls++;
        return true;
      };
      // The group layer's admission: this stranger may sync ONLY group aa11.
      mB.allowStrangerGroupSync = (peer, gidHex) async =>
          peer == stranger && gidHex == 'aa11';

      // A whole groupEntry from a stranger routes to the STRANGER callback
      // (the guarded service half judges it), never the accepted one.
      tB.inject(
        stranger,
        const WireEnvelope.groupEntry(
          '{"m":{"gid":"aa11"}}',
        ).withFrameId('grp:aa11:9').encode(),
      );
      await _settle();
      expect(strangerCalls, 1);
      expect(acceptedCalls, 0);

      // Chunks for the ADMITTED group reassemble and fire the stranger path.
      for (final fr in _chunkFrames(bundle, 'grp:aa11:7')) {
        tB.inject(stranger, fr);
        await _settle();
      }
      expect(strangerCalls, 2);
      expect(viaStranger, bundle);

      // Chunks for a group the admission REFUSES never reassemble (no RAM
      // spent, nothing fires) — silent drop.
      for (final fr in _chunkFrames(bundle, 'grp:bb22:7')) {
        tB.inject(stranger, fr);
        await _settle();
      }
      expect(strangerCalls, 2);
      expect(acceptedCalls, 0);
    },
  );

  test('out-of-order chunks still reassemble byte-exact', () async {
    String? gotJson;
    mB.onGroupEntry = (_, json) {
      gotJson = json;
      return true;
    };
    final frames = _chunkFrames(bundle, 'grp:z:2').reversed.toList();
    for (final fr in frames) {
      tB.inject(a, fr);
      await _settle();
    }
    expect(gotJson, bundle);
  });

  /// A chunk claiming more slices than any transfer can hold is refused
  /// before it costs a reassembly slot.
  ///
  /// The byte cap bounds what a transfer may WEIGH, and nothing bounded how
  /// many entries it could put in the parts map. A sender claiming a count in
  /// the billions and delivering EMPTY slices adds a map entry each time and
  /// not one byte, so the weight check never fires (report9 X-10).
  ///
  /// The harm is observable without measuring memory: reassembly slots are
  /// capped at eight and the ninth evicts the least-recently-advanced partial.
  /// So the hostile claim throws away honest work in flight, and that is what
  /// this asserts.
  test('a chunk claiming an impossible slice count costs nothing', () async {
    var completed = 0;
    mB.onGroupEntry = (_, _) {
      completed++;
      return true;
    };

    // Eight honest transfers in flight, each missing its last chunk. The
    // first one is the least recently advanced, so it is next to be evicted.
    final pending = <List<Uint8List>>[];
    for (var t = 0; t < 8; t++) {
      final frames = _chunkFrames(bundle, 'grp:z:hold$t');
      expect(frames.length, greaterThan(1), reason: 'need a partial to hold');
      for (final fr in frames.take(frames.length - 1)) {
        tB.inject(a, fr);
        await _settle();
      }
      pending.add(frames);
    }
    expect(completed, 0, reason: 'nothing is complete yet');

    // One hostile chunk: a count nothing could ever deliver, carrying nothing.
    tB.inject(
      a,
      groupEntryChunkEnvelope(
        transferId: 'grp:z:flood',
        index: 0,
        count: 1 << 30,
        data: Uint8List(0),
      ).withFrameId('grpc:flood:0').encode(),
    );
    await _settle();

    // Finish the oldest honest transfer.
    tB.inject(a, pending.first.last);
    await _settle();
    expect(
      completed,
      1,
      reason:
          'the hostile claim took a reassembly slot and evicted an honest '
          'partial — a transfer that was making progress is now unfinishable',
    );
  });

  test('an incomplete snapshot never fires onGroupEntry', () async {
    var calls = 0;
    mB.onGroupEntry = (_, _) {
      calls++;
      return true;
    };
    final frames = _chunkFrames(bundle, 'grp:z:3');
    // Deliver everything EXCEPT the last chunk.
    for (final fr in frames.take(frames.length - 1)) {
      tB.inject(a, fr);
      await _settle();
    }
    expect(calls, 0, reason: 'a partial snapshot must not ingest');
  });

  test(
    'document chunks are accepted-contact-only and reassemble once',
    () async {
      final frame = jsonEncode({'v': 1, 'body': 'd' * 9000});
      final chunks = _documentChunkFrames(frame, 'doc:${_id(10).hex}:7');
      String? received;
      var calls = 0;
      mB.onCloudDocumentFrame = (peer, json) async {
        expect(peer, a);
        received = json;
        calls++;
        return true;
      };
      for (final chunk in chunks.reversed) {
        expect(chunk.length, lessThanOrEqualTo(6144));
        tB.inject(a, chunk);
        await _settle();
      }
      expect(received, frame);
      expect(calls, 1);
      tB.inject(a, chunks.first);
      await _settle();
      expect(calls, 1);

      final stranger = _id(9);
      for (final chunk in _documentChunkFrames(frame, 'doc:${_id(10).hex}:8')) {
        tB.inject(stranger, chunk);
        await _settle();
      }
      expect(calls, 1, reason: 'document frames never use stranger admission');
    },
  );

  // ── audit XV-11 ───────────────────────────────────────────────────────────

  /// A sender with nobody on the other end: the live leg goes nowhere, so every
  /// durable frame it produces stays in its outbox to be counted.
  Future<({MessagingService messaging, HiddenVolumeStorage storage})> sender(
    NodeId me,
    List<NodeId> destinations,
  ) async {
    final transport = _Link(me);
    final storage = HiddenVolumeStorage(_memOpener());
    await storage.open(password: 'send', createIfMissing: true);
    // Accepted, or the outbox flush retires frames addressed to a stranger and
    // the count below would measure the flush rather than the enqueue.
    for (final peer in destinations) {
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
    }
    final messaging = MessagingService(transport, storage)..start();
    addTearDown(messaging.dispose);
    return (messaging: messaging, storage: storage);
  }

  test(
    'two snapshots colliding in 31 bits are still two durable frames',
    () async {
      // The frame id used to carry `bundleJson.hashCode & 0x7fffffff`, and the
      // durable outbox is keyed by frame id: `enqueueOutboxFrame` returns early
      // on an id it already holds. So the SECOND of two colliding snapshots was
      // never persisted and never re-driven — the newer group state was lost
      // with no error anywhere (audit XV-11).
      final collision = _hashCodeCollision();
      expect(
        collision.a.hashCode & 0x7fffffff,
        collision.b.hashCode & 0x7fffffff,
        reason: 'the fixture itself must be a genuine 31-bit collision',
      );
      expect(collision.a, isNot(collision.b));

      final s = await sender(a, [b]);
      await s.messaging.sendGroupSnapshot(b, 'aa11', collision.a);
      await s.messaging.sendGroupSnapshot(b, 'aa11', collision.b);

      expect(
        (await s.storage.pendingOutboxFrames()).map((f) => f.frameId).toSet(),
        hasLength(2),
        reason: 'two distinct snapshots are two distinct durable frames',
      );

      // Control: re-sending the SAME snapshot must still dedup, or the id has
      // simply stopped being content-addressed.
      await s.messaging.sendGroupSnapshot(b, 'aa11', collision.a);
      expect(
        (await s.storage.pendingOutboxFrames()).map((f) => f.frameId).toSet(),
        hasLength(2),
        reason: 'a re-drive of the same snapshot is the same frame',
      );
    },
  );

  test('one snapshot to two members is two durable frames', () async {
    // A group snapshot fans out to EVERY member through the same call, and the
    // id named only the group and the content — so the durable outbox held one
    // row and every member after the first lost its re-drive. Exactly the
    // defect `gcr:` had (audit XV-02), still live here (audit XV-11).
    final c = _id(3);
    final s = await sender(a, [b, c]);
    const snapshot = '{"m":{"name":"Pics"}}';

    await s.messaging.sendGroupSnapshot(b, 'aa11', snapshot);
    await s.messaging.sendGroupSnapshot(c, 'aa11', snapshot);

    final pending = await s.storage.pendingOutboxFrames();
    expect(
      pending.map((f) => f.peerHex).toSet(),
      {b.hex, c.hex},
      reason: 'each member needs its own durable frame',
    );
    expect(pending.map((f) => f.frameId).toSet(), hasLength(2));
  });

  test('two senders cannot share one reassembly slot', () async {
    // Reassembly was keyed by transferId ALONE. A transferId names a group and
    // a content digest — anything a member can compute, or simply copy off a
    // chunk it received. So a second sender landed in the first one's slot:
    // `parts.containsKey` dropped its slices as duplicates until it supplied
    // the one index still missing, and the joined bundle was a SPLICE of two
    // senders' bytes that no signature check accepts. The honest snapshot never
    // arrives (audit XV-11).
    //
    // This lands after the per-(peer, frameId) dedup gate: the two senders use
    // identical chunk frame ids, and XV-02 already made the seen-set per peer,
    // so both chunk streams really do reach reassembly.
    final c = _id(3);
    await sB.upsertContact(Contact(nodeId: c, status: ContactStatus.accepted));
    final fromA = bundle;
    final fromC = bundle.replaceAll('y', 'z'); // same length → same chunk count

    final received = <({NodeId peer, String json})>[];
    mB.onGroupEntry = (peer, json) {
      received.add((peer: peer, json: json));
      return true;
    };

    const sharedTid = 'grp:aa11:same-digest';
    final chunksA = _chunkFrames(fromA, sharedTid);
    final chunksC = _chunkFrames(fromC, sharedTid);
    expect(chunksA.length, chunksC.length);
    expect(chunksA.length, greaterThan(1), reason: 'must actually split');

    // A gets all the way to its last chunk, then C sends a complete transfer.
    for (final frame in chunksA.take(chunksA.length - 1)) {
      tB.inject(a, frame);
      await _settle();
    }
    for (final frame in chunksC) {
      tB.inject(c, frame);
      await _settle();
    }
    expect(received, hasLength(1));
    expect(received.single.peer, c);
    expect(
      received.single.json,
      fromC,
      reason: "C's bundle must be C's bytes only — not a splice with A's",
    );

    // And A's partial was never consumed by C's transfer: its last chunk still
    // completes A's own snapshot.
    tB.inject(a, chunksA.last);
    await _settle();
    expect(received, hasLength(2));
    expect(received.last.peer, a);
    expect(received.last.json, fromA);
  });

  test('a partial that keeps advancing outlives idle ones', () async {
    // The concurrency cap evicted `keys.first` — insertion order, so the
    // OLDEST-STARTED partial, which is precisely the big slow transfer that is
    // still making progress. (A wall-clock TTL, which the audit suggested,
    // would have picked the same victim for the same wrong reason.) Ordering by
    // last progress instead drops only genuinely stalled partials (audit
    // XV-11).
    var calls = 0;
    String? gotJson;
    mB.onGroupEntry = (_, json) {
      gotJson = json;
      calls++;
      return true;
    };

    final live = _chunkFrames(bundle, 'grp:aa11:live');
    expect(live.length, greaterThanOrEqualTo(3));
    final idle = [
      for (var i = 0; i < 7; i++) _chunkFrames(bundle, 'grp:aa11:idle$i'),
    ];

    tB.inject(a, live.first); // oldest-started
    await _settle();
    for (final transfer in idle) {
      tB.inject(a, transfer.first);
      await _settle();
    }

    tB.inject(a, live[1]); // …but the one still moving
    await _settle();

    // One transfer more than the cap allows: something has to go.
    tB.inject(a, _chunkFrames(bundle, 'grp:aa11:overflow').first);
    await _settle();

    for (final frame in live.skip(2)) {
      tB.inject(a, frame);
      await _settle();
    }
    expect(calls, 1, reason: 'the advancing transfer must survive the squeeze');
    expect(gotJson, bundle);

    // …and the squeeze was real: the stalest partial IS gone, so finishing it
    // reassembles nothing.
    for (final frame in idle.first.skip(1)) {
      tB.inject(a, frame);
      await _settle();
    }
    expect(calls, 1, reason: 'the idle partial was the one evicted');
  });

  test(
    'whole group snapshot joins persistence before ACK or queue release',
    () async {
      final entered = Completer<void>(), persisted = Completer<void>();
      mB.onGroupEntry = (_, _) async {
        entered.complete();
        await persisted.future;
        return true;
      };
      final frame = const WireEnvelope.groupEntry(
        '{}',
      ).withFrameId('legacy-whole-held').encode();
      try {
        tB.inject(a, frame);
        await entered.future;
        await _settle();
        expect(
          mB.inboundAdmission.queuedFrames,
          1,
          reason: 'the group write still owns its admission reservation',
        );
        expect(
          tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
          isEmpty,
          reason: 'the snapshot is not durable yet',
        );
      } finally {
        persisted.complete();
      }
      await _settle();
      expect(mB.inboundAdmission.queuedFrames, 0);
      expect(
        tB.sent
            .map(WireEnvelope.decode)
            .where((e) => e.kind == WireKind.ack)
            .map((e) => e.id),
        contains('legacy-whole-held'),
      );
    },
  );

  test('a declined whole group snapshot retries the identical frame', () async {
    var stored = false, calls = 0;
    mB.onGroupEntry = (_, _) async {
      calls++;
      return stored;
    };
    final frame = const WireEnvelope.groupEntry(
      '{}',
    ).withFrameId('legacy-whole-retry').encode();
    tB.inject(a, frame);
    await _settle();
    expect(calls, 1);
    expect(
      tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
      isEmpty,
    );
    stored = true;
    tB.inject(a, frame);
    await _settle();
    expect(calls, 2, reason: 'an uncommitted attempt must not consume dedup');
    tB.inject(a, frame);
    await _settle();
    expect(calls, 2, reason: 'a committed retry only needs another ACK');
  });

  test(
    'group chunks retain every ACK until the complete write succeeds',
    () async {
      final frames = _chunkFrames(bundle, 'grp:aa11:durable');
      var fail = true, calls = 0;
      mB.onGroupEntry = (_, _) async {
        calls++;
        if (fail) throw StateError('injected group persistence failure');
        return true;
      };
      for (final frame in frames) {
        tB.inject(a, frame);
        await _settle();
      }
      expect(calls, 1);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        isEmpty,
        reason: 'all slices must remain in the sender outbox',
      );
      fail = false;
      for (final frame in frames) {
        tB.inject(a, frame);
        await _settle();
      }
      expect(calls, 2);
      final ackIds = tB.sent
          .map(WireEnvelope.decode)
          .where((e) => e.kind == WireKind.ack)
          .map((e) => e.id)
          .toSet();
      expect(
        ackIds,
        frames.map(WireEnvelope.decode).map((e) => e.frameId).toSet(),
      );
      for (final frame in frames) {
        tB.inject(a, frame);
        await _settle();
      }
      expect(
        calls,
        2,
        reason: 'persisted slices must not launch another write',
      );
    },
  );

  test(
    'partial receiver restart leaves the actual sender outbox recoverable',
    () async {
      final tA = _Link(a)
        ..peer = tB
        ..passLimit = 2;
      tB.peer = tA;
      final sA = HiddenVolumeStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      final mA = MessagingService(tA, sA)..start();
      addTearDown(mA.dispose);
      await sA.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      var committed = 0;
      mB.onGroupEntry = (_, _) async {
        committed++;
        return true;
      };
      await mA.sendGroupSnapshot(b, 'aa11', bundle);
      await _settle();
      final frames = tA.sent
          .where((w) => WireEnvelope.decode(w).kind == WireKind.groupEntryChunk)
          .toList();
      expect(frames.length, greaterThan(2));
      expect(committed, 0);
      expect(await sA.pendingOutboxFrames(), hasLength(frames.length));
      await mB.dispose();
      final restartedLink = _Link(b)..peer = tA;
      tA.peer = restartedLink;
      final restarted = MessagingService(restartedLink, sB)..start();
      addTearDown(restarted.dispose);
      restarted.onGroupEntry = (_, json) async {
        expect(json, bundle);
        committed++;
        return true;
      };
      for (final frame in frames) {
        restartedLink.inject(a, frame);
        await _settle();
      }
      await _settle();
      expect(committed, 1);
      expect(
        await sA.pendingOutboxFrames(),
        isEmpty,
        reason:
            'all original frames retire only after the recovered snapshot lands',
      );
    },
  );

  test('group persistence is joined during messaging shutdown', () async {
    final entered = Completer<void>(), persisted = Completer<void>();
    mB.onGroupEntry = (_, _) async {
      entered.complete();
      await persisted.future;
      return true;
    };
    tB.inject(
      a,
      const WireEnvelope.groupEntry('{}').withFrameId('legacy-close').encode(),
    );
    await entered.future;
    var closed = false;
    final closing = mB.dispose().then((_) {
      closed = true;
    });
    try {
      await _settle();
      expect(closed, isFalse);
    } finally {
      persisted.complete();
      await closing;
    }
  });

  test('chunk ACKs retain the authenticated physical sender device', () async {
    final physicalSender = _id(77);
    mB.onGroupEntry = (_, _) async => true;
    for (final frame in _chunkFrames(bundle, 'grp:aa11:device-ack')) {
      tB.inject(a, frame, device: physicalSender);
      await _settle();
    }
    final ackDestinations = [
      for (var i = 0; i < tB.sent.length; i++)
        if (WireEnvelope.decode(tB.sent[i]).kind == WireKind.ack)
          tB.destinations[i],
    ];
    expect(ackDestinations, isNotEmpty);
    expect(ackDestinations, everyElement(physicalSender));
  });

  test(
    'a legacy group frame with only a claimed sender cannot consume an ACK',
    () async {
      var applies = 0;
      mB.onGroupEntry = (_, _) async {
        applies++;
        return true;
      };
      final wire = const WireEnvelope.groupEntry(
        '{}',
      ).withFrameId('legacy-unbound').encode();
      tB.inject(a, wire, provenance: SenderProvenance.claimed);
      await _settle();
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        isEmpty,
      );
      tB.inject(a, wire);
      await _settle();
      expect(
        applies,
        2,
        reason: 'the attributed copy still needs durable admission',
      );
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        hasLength(1),
      );
    },
  );

  test(
    'canonical whole snapshot IDs reject substituted bodies and other wire kinds',
    () async {
      final source = _Link(a);
      final sA = HiddenVolumeStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      final mA = MessagingService(source, sA)..start();
      addTearDown(mA.dispose);
      await sA.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      await mA.sendGroupSnapshot(b, 'aa11', '{}');
      final original = source.sent
          .map(WireEnvelope.decode)
          .firstWhere((e) => e.kind == WireKind.groupEntry);
      var calls = 0;
      mB.onGroupEntry = (_, body) async {
        expect(body, '{}');
        calls++;
        return true;
      };
      tB.inject(
        a,
        const WireEnvelope.groupEntry(
          '{"tampered":1}',
        ).withFrameId(original.frameId!).encode(),
      );
      tB.inject(
        a,
        const WireEnvelope.reconnect(
          '',
        ).withFrameId(original.frameId!).encode(),
      );
      await _settle();
      expect(calls, 0);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        isEmpty,
      );
      tB.inject(a, original.encode(), provenance: SenderProvenance.claimed);
      await _settle();
      expect(calls, 1);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        hasLength(1),
      );
    },
  );

  test(
    'canonical chunk digest mismatch preserves every original retry',
    () async {
      final source = _Link(a);
      final sA = HiddenVolumeStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      final mA = MessagingService(source, sA)..start();
      addTearDown(mA.dispose);
      await sA.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      await mA.sendGroupSnapshot(b, 'aa11', bundle);
      final frames = source.sent
          .map(WireEnvelope.decode)
          .where((e) => e.kind == WireKind.groupEntryChunk)
          .toList();
      var calls = 0;
      mB.onGroupEntry = (_, body) async {
        expect(body, bundle);
        calls++;
        return true;
      };
      final first = parseGroupEntryChunk(frames.first.body);
      final badData = Uint8List.fromList(first.data)..[0] ^= 1;
      final bad = groupEntryChunkEnvelope(
        transferId: first.transferId,
        index: first.index,
        count: first.count,
        data: badData,
      ).withFrameId(frames.first.frameId!).encode();
      tB.inject(a, bad, provenance: SenderProvenance.claimed);
      for (final frame in frames.skip(1)) {
        tB.inject(a, frame.encode());
        await _settle();
      }
      expect(calls, 0);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        isEmpty,
      );
      for (final frame in frames) {
        tB.inject(a, frame.encode());
        await _settle();
      }
      expect(calls, 1);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        hasLength(frames.length),
      );
    },
  );

  test(
    'handler replacement cannot inherit a completed group receipt',
    () async {
      var writes = 0;
      mB.onGroupEntry = (_, _) async {
        writes++;
        return true;
      };
      final frame = const WireEnvelope.groupEntry(
        '{}',
      ).withFrameId('legacy-new-owner').encode();
      tB.inject(a, frame);
      await _settle();
      expect(writes, 1);
      var accept = false;
      mB.onGroupEntry = (_, _) async {
        writes++;
        return accept;
      };
      tB.inject(a, frame);
      await _settle();
      expect(writes, 2);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        hasLength(1),
      );
      accept = true;
      tB.inject(a, frame);
      await _settle();
      expect(writes, 3);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        hasLength(2),
      );
    },
  );

  test(
    'a replaced in-flight group handler cannot acknowledge its old write',
    () async {
      final entered = Completer<void>(), oldWrite = Completer<void>();
      mB.onGroupEntry = (_, _) async {
        entered.complete();
        await oldWrite.future;
        return true;
      };
      final frame = const WireEnvelope.groupEntry(
        '{}',
      ).withFrameId('legacy-inflight-owner').encode();
      tB.inject(a, frame);
      await entered.future;
      var currentWrites = 0;
      mB.onGroupEntry = (_, _) async {
        currentWrites++;
        return true;
      };
      oldWrite.complete();
      await _settle();
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        isEmpty,
      );
      tB.inject(a, frame);
      await _settle();
      expect(currentWrites, 1);
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        hasLength(1),
      );
    },
  );

  test(
    'a frame arriving before group handlers are installed remains retryable',
    () async {
      final frame = const WireEnvelope.groupEntry(
        '{}',
      ).withFrameId('legacy-early').encode();
      tB.inject(a, frame);
      await _settle();
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        isEmpty,
      );
      var writes = 0;
      mB.onGroupEntry = (_, _) async {
        writes++;
        return true;
      };
      tB.inject(a, frame);
      await _settle();
      expect(writes, 1);
    },
  );

  test(
    'a committed own-device snapshot resolves fallback ACK targets only once',
    () async {
      final physicalSender = _id(77);
      mB.selfIdentityHex = () async => a.hex;
      var lookups = 0;
      mB.myOtherDevices = () async {
        lookups++;
        return [physicalSender];
      };
      mB.onGroupEntry = (_, _) async => true;
      final frames = _chunkFrames(bundle, 'grp:aa11:batch-acks');
      for (final frame in frames) {
        tB.inject(a, frame);
        await _settle();
      }
      expect(
        lookups,
        1,
        reason: 'one device-journal fold for the whole ACK batch',
      );
      expect(
        tB.sent.where((w) => WireEnvelope.decode(w).kind == WireKind.ack),
        hasLength(frames.length),
      );
      expect(tB.destinations, everyElement(physicalSender));
    },
  );

  test(
    'document chunks withhold ACK until persistence becomes terminal',
    () async {
      final frame = jsonEncode({'v': 1, 'body': 'r' * 9000});
      final chunks = _documentChunkFrames(frame, 'doc:${_id(11).hex}:9');
      var terminal = false;
      var calls = 0;
      mB.onCloudDocumentFrame = (_, _) async {
        calls++;
        return terminal;
      };

      for (final chunk in chunks) {
        tB.inject(a, chunk);
        await _settle();
      }
      expect(calls, 1);
      expect(
        tB.sent.where((wire) => WireEnvelope.decode(wire).kind == WireKind.ack),
        isEmpty,
        reason: 'a local storage failure must leave every chunk retryable',
      );

      terminal = true;
      for (final chunk in chunks) {
        tB.inject(a, chunk);
        await _settle();
      }
      expect(calls, 2);
      final ackIds = tB.sent
          .map(WireEnvelope.decode)
          .where((envelope) => envelope.kind == WireKind.ack)
          .map((envelope) => envelope.id)
          .whereType<String>()
          .toSet();
      expect(ackIds, hasLength(chunks.length));

      tB.inject(a, chunks.first);
      await _settle();
      expect(calls, 2, reason: 'terminal chunks dedup and only re-ack');
    },
  );

  test('a destination whose queue is not draining stops being fed', () async {
    // Replication fans every change out to every member, so a member that never
    // acknowledges accumulates one batch per change with no end. Measured on
    // the stand: 3473 frames, 9.56 MB, queued to a linked device wiped four
    // days earlier and still growing at every app start.
    //
    // Nothing is dropped here — we decline to ADD. What must survive is the
    // guarantee that two devices reach the same state, and that never came from
    // this queue: a device that returns asks what it is missing and the sender
    // recomputes it. See `_backedUp`.
    final s = await sender(a, [b]);
    var pending = 0;
    var i = 0;
    // Push past the cap. Each snapshot is distinct (content-addressed id), so
    // every one is a fresh durable frame until the guard trips.
    while (i < 400) {
      await s.messaging.sendGroupSnapshot(b, 'aa11', 'snapshot-$i');
      final now = (await s.storage.pendingOutboxFrames()).length;
      if (now == pending) break; // the guard has stopped accepting
      pending = now;
      i++;
    }
    expect(
      i,
      lessThan(400),
      reason: 'the queue must stop growing well before 400 snapshots',
    );
    expect(
      pending,
      lessThanOrEqualTo(300),
      reason: 'and it must settle near the cap, not wander past it',
    );

    // The frames already queued are UNTOUCHED — this is back-pressure, not a
    // purge, and losing them is exactly what must not happen.
    expect(pending, greaterThan(200));
  });

  test('a peer that drains is fed again', () async {
    // The cap lifts by itself: acks retire frames, the count falls, and the
    // next snapshot is queued as before. Nothing has to notice the peer is
    // back — the queue length IS the signal.
    final s = await sender(a, [b]);
    var i = 0;
    var pending = 0;
    while (i < 400) {
      await s.messaging.sendGroupSnapshot(b, 'aa11', 'snapshot-$i');
      final now = (await s.storage.pendingOutboxFrames()).length;
      if (now == pending) break;
      pending = now;
      i++;
    }
    expect(pending, greaterThan(0));

    // Drain it the way an ack would.
    for (final f in await s.storage.pendingOutboxFrames()) {
      s.messaging.debugRetireOutboxFrame(f.peerHex, f.frameId);
    }
    await pumpEventQueue();
    expect((await s.storage.pendingOutboxFrames()), isEmpty);

    await s.messaging.sendGroupSnapshot(b, 'aa11', 'after-the-drain');
    expect(
      (await s.storage.pendingOutboxFrames()),
      isNotEmpty,
      reason: 'replication resumes once the backlog has cleared',
    );
  });

  test('the cap holds on the FIRST snapshot after a restart', () async {
    // The counter behind the cap is refreshed by the outbox flush, which first
    // runs up to one interval after the service starts. The replication burst
    // it exists to bound — `nudgeGroupSyncAll` — happens AT start-up, inside
    // that window. Unseeded, the cap read zero and waved through exactly the
    // batch it is there to stop, which is why the live stand showed no
    // suppression at all on a restart.
    //
    // This is the near miss, not the obvious case: a queue that is ALREADY
    // full, and a service that has not flushed yet.
    final s = await sender(a, [b]);
    // Fill the store directly, so nothing has updated any in-memory counter.
    for (var i = 0; i < 300; i++) {
      await s.storage.enqueueOutboxFrame(
        'grp:aa11:pre$i:${b.hex}',
        b.hex,
        WireEnvelope.groupEntry('pre-existing-$i').encode(),
      );
    }
    final before = (await s.storage.pendingOutboxFrames()).length;
    expect(before, greaterThanOrEqualTo(300));

    await s.messaging.sendGroupSnapshot(b, 'aa11', 'the-first-one-after-boot');

    expect(
      (await s.storage.pendingOutboxFrames()).length,
      before,
      reason: 'the very first snapshot after a restart must already be capped',
    );
  });

  test('the cap releases queued STATE but never an event frame', () async {
    // Once we have decided not to queue more state for a peer, the state
    // already queued is equally moot — the peer asks for what it is missing
    // when it returns. Events are different: an ack or a call signal that is
    // dropped is gone, nothing recomputes it. On the stand this is the
    // difference between letting go of 9.6 MB and losing a message receipt.
    final s = await sender(a, [b]);
    for (var i = 0; i < 300; i++) {
      await s.storage.enqueueOutboxFrame(
        'grp:aa11:pre$i:${b.hex}',
        b.hex,
        WireEnvelope.groupEntry('pre-$i').encode(),
      );
    }
    // One of each kind of event frame, alongside the state.
    await s.storage.enqueueOutboxFrame(
      'call:c1:offer',
      b.hex,
      WireEnvelope.callSignal('{}').encode(),
    );
    await s.storage.enqueueOutboxFrame(
      'p2p:ep:1',
      b.hex,
      WireEnvelope.p2pEndpoints('{}').encode(),
    );

    await s.messaging.sendGroupSnapshot(b, 'aa11', 'trips-the-cap');
    await pumpEventQueue();

    final left = (await s.storage.pendingOutboxFrames())
        .map((f) => f.frameId)
        .toSet();
    expect(
      left.where((id) => id.startsWith('grp:')),
      isEmpty,
      reason: 'replicated state is released',
    );
    expect(
      left,
      containsAll(<String>['call:c1:offer', 'p2p:ep:1']),
      reason: 'events are NOT — nothing recomputes those',
    );
  });
}
