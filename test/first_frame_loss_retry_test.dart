import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// A 1:1 link that LOSES THE FIRST live frame of one kind and delivers every
/// frame after it.
///
/// This is the shape observed on the two-device stand: the first live frame of
/// a send is dropped almost every time, and what actually delivers the message
/// is the outbox retry ~6s later. Ordinary text survives that because it is
/// re-sent; a file OFFER was excluded from the retry loop and therefore had no
/// second chance at all.
class _LossyLink implements VeilTransport {
  _LossyLink(this._me, {this.loseFirstKind, this.loseAll = const {}});

  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _LossyLink? peer;

  /// The one kind whose FIRST frame is swallowed. Null = a perfect link.
  final WireKind? loseFirstKind;

  /// Kinds swallowed EVERY time. Used to take the event-log reconciliation
  /// route out of the picture, so a test measures the retry loop itself.
  final Set<WireKind> loseAll;
  bool _lostOne = false;

  /// Every frame this side ATTEMPTED to send, by kind — dropped ones included.
  /// Lets a test prove the retry re-sent an offer without re-pushing bytes.
  final Map<WireKind, int> sent = {};

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
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
    final kind = WireEnvelope.decode(payload).kind;
    sent[kind] = (sent[kind] ?? 0) + 1;
    if (loseAll.contains(kind)) return;
    if (kind == loseFirstKind && !_lostOne) {
      _lostOne = true;
      return; // the first live frame never reaches the peer
    }
    peer?._in.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

/// Records every mailbox deposit, so a test can count how many copies of one
/// offer piled up at the recipient's relay.
class _RecordingSink implements MailboxSink {
  final stashed = <(NodeId, Uint8List)>[];

  @override
  bool backgroundDrainPaused = false;
  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async => stashed.add((recipient, payload));
  @override
  void nudgeDrain() {}
  @override
  void noteActivity() {}
}

void main() {
  late NodeId a, b;
  late _LossyLink tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  // Each test picks which kind the link swallows before the services start.
  //
  // [muted] is dropped on BOTH sides for the whole test. Every case below mutes
  // the event-log reconciliation frames, because reconciliation is a SECOND,
  // independent recovery route: it re-ships a missing filePost when the peer
  // notices the gap, which masks whether the retry loop did anything at all.
  // Muting it is what makes these assertions about the retry loop.
  Future<void> boot({
    WireKind? lose,
    Set<WireKind> muted = const {WireKind.sync, WireKind.fileQuery},
  }) async {
    a = _id(1);
    b = _id(2);
    tA = _LossyLink(a, loseFirstKind: lose, loseAll: muted);
    tB = _LossyLink(b, loseAll: muted);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_mem());
    sB = HiddenVolumeStorage(_mem());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    const fast = Duration(milliseconds: 60);
    mA = MessagingService(
      tA,
      sA,
      contentReRequestInterval: fast,
      contentPacing: Duration.zero,
    )..start();
    mB = MessagingService(
      tB,
      sB,
      contentReRequestInterval: fast,
      contentPacing: Duration.zero,
    )..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    addTearDown(() async {
      await mA.dispose();
      await mB.dispose();
    });
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  Future<List<Message>> waitMessages(
    HiddenVolumeStorage s,
    NodeId peer,
    bool Function(Message) where, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final hit = (await s.loadMessages(peer.hex)).where(where).toList();
      if (hit.isNotEmpty) return hit;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return (await s.loadMessages(peer.hex)).where(where).toList();
  }

  Uint8List rnd(int n, int seed) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  test('a TEXT whose first live frame is lost still arrives — the outbox '
      'retry is what delivers it', () async {
    await boot(lose: WireKind.message);

    await mA.sendText(b, 'the first frame of this one is lost');
    await settle();
    expect(
      await sB.loadMessages(a.hex),
      isEmpty,
      reason: 'precondition: the first live frame really was swallowed',
    );

    await mA.flushOutbox();
    final got = await waitMessages(sB, a, (m) => !m.isFile);

    expect(got, hasLength(1), reason: 'the retry delivered the message');
    expect(got.single.body, 'the first frame of this one is lost');
  });

  test('a FILE OFFER whose first live frame is lost still arrives — the retry '
      're-advertises the manifest', () async {
    await boot(lose: WireKind.contentManifest);

    // > 128 KiB → the content path: a manifest OFFER, then a receiver-initiated
    // pull. Losing that one small frame used to lose the file permanently.
    await mA.sendFile(b, rnd(200 * 1024, 7), 'holiday.jpg');
    await settle();
    expect(
      (await sB.loadMessages(a.hex)).where((m) => m.isFile),
      isEmpty,
      reason: 'precondition: the offer frame really was swallowed',
    );
    final sentByA = (await sA.loadMessages(b.hex)).single;

    await mA.flushOutbox();
    final got = await waitMessages(
      sB,
      a,
      (m) => m.isFile,
      timeout: const Duration(seconds: 5),
    );

    expect(got, hasLength(1), reason: 'the retry re-advertised the offer');
    expect(got.single.fileName, 'holiday.jpg');
    // The re-advertised offer must carry THIS message's event identity, not a
    // bare cid-level manifest: the recipient's row has to be the same event the
    // sender is still retrying, or the two never converge and the ack never
    // retires it. (A cid-keyed serve manifest is stored with its event fields
    // STRIPPED, so re-sending it verbatim loses exactly this.)
    expect(
      got.single.id,
      sentByA.id,
      reason: "B's row is A's event, re-bound by the retry",
    );
    expect(
      got.single.author,
      a.hex,
      reason: 'and it folds into A\'s author stream',
    );
  });

  test('the retry re-advertises the OFFER and never re-pushes file BYTES — a '
      'small inline file is not re-sent frame by frame', () async {
    await boot(lose: WireKind.fileMeta);

    // A is ALREADY serving an unrelated large file. That matters: the retry
    // finds a message's offer by CONTENT ID, and a lookup that fell back to
    // "whatever manifest is around" would hand this manifest to the unrelated
    // inline file below — offering the wrong bytes under its event.
    await mA.sendFile(b, rnd(200 * 1024, 9), 'unrelated-large.bin');
    await waitMessages(sB, a, (m) => m.isFile);
    await waitMessages(
      sA,
      b,
      (m) => m.status == MessageStatus.delivered,
    ); // acked → out of the retry loop
    await settle();

    // < 128 KiB → the small inline path: the bytes themselves travel as
    // fileMeta + fileChunk, and there is no manifest anywhere. Re-driving
    // THOSE on every retry tick is the cost the blanket file exclusion was
    // avoiding, so it must stay avoided.
    await mA.sendFile(b, rnd(4 * 1024, 3), 'note.txt');
    await settle();

    final offersAfterSend = tA.sent[WireKind.contentManifest] ?? 0;
    final metaAfterSend = tA.sent[WireKind.fileMeta] ?? 0;
    final chunksAfterSend = tA.sent[WireKind.fileChunk] ?? 0;
    expect(
      chunksAfterSend,
      greaterThan(0),
      reason: 'precondition: the inline path really did push byte frames',
    );
    final inline = (await sA.loadMessages(
      b.hex,
    )).firstWhere((m) => m.fileName == 'note.txt');
    expect(
      inline.status,
      MessageStatus.sent,
      reason: 'precondition: still un-acked, so the retry loop considers it',
    );

    for (var i = 0; i < 3; i++) {
      await mA.flushOutbox();
      await settle();
    }

    expect(
      tA.sent[WireKind.fileMeta] ?? 0,
      metaAfterSend,
      reason: 'no re-pushed file metadata',
    );
    expect(
      tA.sent[WireKind.fileChunk] ?? 0,
      chunksAfterSend,
      reason: 'no re-pushed file bytes',
    );
    expect(
      tA.sent[WireKind.contentManifest] ?? 0,
      offersAfterSend,
      reason: 'and no offer invented for a file that never had a manifest',
    );
    expect(
      (await sB.loadMessages(a.hex)).where((m) => m.isFile).map((m) => m.id),
      isNot(contains(inline.id)),
      reason: "the inline file's event never surfaced as somebody else's offer",
    );
  });

  test('the retried offer is deposited under the key the ORIGINAL send used, '
      'so the mailbox holds one copy and not a growing pile', () async {
    await boot(lose: WireKind.contentManifest);
    final sink = _RecordingSink();
    mA.attachMailbox(sink);

    await mA.sendFile(b, rnd(200 * 1024, 5), 'holiday.jpg');
    await settle();
    int offerDeposits() => sink.stashed
        .where((s) => WireEnvelope.decode(s.$2).kind == WireKind.contentManifest)
        .length;
    expect(
      offerDeposits(),
      1,
      reason: 'precondition: the original send deposited the offer once',
    );

    await mA.flushOutbox();
    await settle();

    // The deposit is keyed `mf:<msgId>`, the same key the original send chose,
    // so the retry's deposit dedups against it. Keying it any other way makes
    // every retry tick leave ANOTHER copy of the same offer at the relay, and
    // the recipient drains the same file offer over and over.
    expect(
      offerDeposits(),
      1,
      reason: 'the retry re-used the original deposit key — no second copy',
    );
  });
}
