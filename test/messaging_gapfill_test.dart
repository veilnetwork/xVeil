import 'dart:async';
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
  Future<void> send(NodeId dst, Uint8List payload,
      {bool anonymous = false}) async {
    if (drop) return; // live datagram lost
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.fileChunk) {
      final frame = parseFileChunk(env.body);
      if (dropChunks.contains(frame.index)) return; // selective chunk loss
      chunkSends++;
    }
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

  /// Inject an inbound frame as if it arrived over the wire from [from] (used to
  /// craft a hand-built envelope the normal send path can't produce).
  void inject(NodeId from, Uint8List payload) =>
      _inbound.add(InboundMessage(src: from, payload: payload));

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

  List<Message> _bodies(List<Message> m) => m;

  test('a message lost on the live path self-heals via the gap-fill beacon',
      () async {
    await mA.sendText(b, 'one');
    await _settle();
    expect((await sB.loadMessages(a.hex)).map((m) => m.body), contains('one'));

    // 'two' is lost on the wire (live drop, no mailbox) — B never sees it live.
    tA.drop = true;
    await mA.sendText(b, 'two');
    await _settle();
    expect((await sB.loadMessages(a.hex)).map((m) => m.body), isNot(contains('two')),
        reason: 'the live datagram was dropped — B must not have it yet');

    // Reconnect: B beacons its high-water (it holds A up to seq 1); A re-ships
    // every event above that — 'two' (seq 2) — over the now-live path.
    tA.drop = false;
    await mB.reconcileOnConnect();
    await _settle();

    final got = await sB.loadMessages(a.hex);
    expect(got.map((m) => m.body), contains('two'),
        reason: 'gap-fill re-shipped the missing message');
    // It landed under the SENDER's (author, seq) — convergent log, no phantom gap.
    final two = got.firstWhere((m) => m.body == 'two');
    expect(two.author, a.hex);
    expect(two.seq, 2);
    final sync = await sB.conversationSync(a.hex);
    expect(sync.highWater[a.hex], 2);
    expect(sync.holes[a.hex], isNull);
  });

  test('an edit lost on the live path self-heals (folds under the editor seq)',
      () async {
    await mA.sendText(b, 'hello');
    await _settle();
    final id = (await sB.loadMessages(a.hex))
        .firstWhere((m) => m.body == 'hello')
        .id;

    // A edits while B cannot hear it — the edit event (seq 2) is lost.
    tA.drop = true;
    await mA.editOwnMessage(id, 'hello (edited)');
    await _settle();
    expect((await sB.loadMessages(a.hex)).firstWhere((m) => m.id == id).body,
        'hello',
        reason: 'B has not heard the edit yet');

    // Heal: B beacons hw=1, A re-ships the edit event at seq 2.
    tA.drop = false;
    await mB.reconcileOnConnect();
    await _settle();

    final healed = (await sB.loadMessages(a.hex)).firstWhere((m) => m.id == id);
    expect(healed.body, 'hello (edited)');
    expect(healed.edited, isTrue);
    // The edit folded under the editor's seq (2), not a fabricated local one, so
    // both devices agree the stream is gap-free up to 2 (the phantom-hole fix).
    final sync = await sB.conversationSync(a.hex);
    expect(sync.highWater[a.hex], 2);
    expect(sync.holes[a.hex], isNull);
  });

  test('a delete of a NEVER-DELIVERED message heals via a void — high-water '
      'advances, the message never resurrects', () async {
    await mA.sendText(b, 'keep'); // seq 1 — B gets it
    await _settle();

    // 'gone' (seq 2) is lost on the wire, then A unsends it before B ever saw it.
    tA.drop = true;
    await mA.sendText(b, 'gone');
    await _settle();
    final goneId = (await sA.loadMessages(b.hex))
        .firstWhere((m) => m.body == 'gone')
        .id;
    await mA.deleteForEveryone(goneId); // tombstones seq 2 on A (del wire dropped)
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

  test('a file lost on the live path self-heals via gap-fill (filePost)',
      () async {
    await mA.sendText(b, 'hi'); // seq 1 — so the file is seq 2 in the stream
    await _settle();

    tA.drop = true;
    final bytes = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    await mA.sendFile(b, bytes, 'photo.bin');
    await _settle();
    expect((await sB.loadMessages(a.hex)).where((m) => m.isFile), isEmpty,
        reason: 'the file frames were dropped — B has no file yet');

    // Reconnect: B beacons hw=1; A re-ships the file (meta seq 2 + chunks).
    tA.drop = false;
    await mB.reconcileOnConnect();
    await _settle();

    final files =
        (await sB.loadMessages(a.hex)).where((m) => m.isFile).toList();
    expect(files, hasLength(1), reason: 'gap-fill re-shipped the file');
    expect(files.single.seq, 2, reason: 'folded under the sender filePost seq');
    expect(await sB.loadFile(files.single.fileId!), bytes,
        reason: 'the blob bytes round-tripped');
    // The file folded under the SENDER's send-time, not B's receive time — so the
    // convergent (effective_ts, author, seq) order is identical on both devices.
    final aFile =
        (await sA.loadMessages(b.hex)).firstWhere((m) => m.isFile);
    expect(files.single.timestamp, aFile.timestamp,
        reason: 'file display time converges to the sender send-time');
    final sync = await sB.conversationSync(a.hex);
    expect(sync.highWater[a.hex], 2);
    expect(sync.holes[a.hex], isNull);
  });

  test('a PARTIALLY-received file resumes — only the MISSING chunks re-send',
      () async {
    await mA.sendText(b, 'hi'); // seq 1
    await _settle();
    // ~3 chunks at 6000 B/chunk. Drop ONLY chunk index 1 on the first push, so
    // B holds chunks 0 and 2 but the transfer is incomplete.
    final bytes = Uint8List.fromList(List.generate(13000, (i) => (i * 7) % 256));
    tA.dropChunks = {1};
    await mA.sendFile(b, bytes, 'big.bin');
    await _settle();
    expect((await sB.loadMessages(a.hex)).where((m) => m.isFile), isEmpty,
        reason: 'one chunk dropped — transfer incomplete, no file message yet');

    // Reconnect: B beacons → A probes (fileQuery) → B NACKs [1] → A re-sends ONLY
    // chunk 1 (resumable), NOT the whole blob.
    tA.dropChunks = {};
    tA.chunkSends = 0;
    await mB.reconcileOnConnect();
    await _settle();

    final files = (await sB.loadMessages(a.hex)).where((m) => m.isFile).toList();
    expect(files, hasLength(1), reason: 'the file completed');
    expect(await sB.loadFile(files.single.fileId!), bytes,
        reason: 'blob bytes round-trip');
    expect(tA.chunkSends, 1,
        reason: 'resumable: only the missing chunk re-sent, not all 3');
  });

  test('an incoming message stores the SENDER send-time verbatim — no '
      'receiver-clock clamp (convergent display order)', () async {
    // Craft a message from A stamped FAR in the future; the receiver must store
    // that exact time (the old code clamped it to the receiver now → divergence).
    const future = 4102444800000; // 2100-01-01
    final wire = const WireEnvelope.message(
      'from the future',
      id: 'fut-1',
      sentAtMs: future,
      seq: 1,
    ).encode();
    tB.inject(a, wire); // arrives at B (mB listens on tB) as if A sent it
    await _settle();
    final m =
        (await sB.loadMessages(a.hex)).firstWhere((x) => x.id == 'fut-1');
    expect(m.timestamp.millisecondsSinceEpoch, future,
        reason: 'stored verbatim, not clamped to the receiver clock');
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
    await sB2.upsertContact(
      Contact(nodeId: a, status: ContactStatus.accepted),
    );
    final mB2 = MessagingService(tB2, sB2)..start();
    addTearDown(mB2.dispose);

    // Reconnect: B2 beacons hw[A]={} (it holds nothing) → A re-ships everything.
    await mB2.reconcileOnConnect();
    await _settle();

    final recovered =
        (await sB2.loadMessages(a.hex)).map((m) => m.body).toSet();
    expect(recovered, containsAll(['m1', 'm2', 'm3']),
        reason: 'the wiped peer recovered the whole conversation from the log');
  });

  test('gap-fill is bidirectional from a single reconnect (beacon-back)',
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
    expect((await sB.loadMessages(a.hex)).map((m) => m.body),
        isNot(contains('a-lost')));
    expect((await sA.loadMessages(b.hex)).map((m) => m.body),
        isNot(contains('b-lost')));

    // One side reconnecting beacons; the handler beacons back, so BOTH heal.
    tA.drop = false;
    tB.drop = false;
    await mB.reconcileOnConnect();
    await _settle();

    expect(_bodies(await sB.loadMessages(a.hex)).map((m) => m.body),
        contains('a-lost'),
        reason: "B recovered A's lost message");
    expect(_bodies(await sA.loadMessages(b.hex)).map((m) => m.body),
        contains('b-lost'),
        reason: "A recovered B's lost message via the beacon-back");
  });
}
