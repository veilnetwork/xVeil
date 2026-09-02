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
import 'package:xveil/domain/chat.dart'
    show Contact, ContactStatus, MessageStatus;
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A transport whose live send goes NOWHERE — models two NAT'd nodes that
/// cannot reach each other directly, so the ONLY delivery path is the mailbox.
class _BlackholeTransport implements VeilTransport {
  _BlackholeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  bool throwOnSend = false;

  /// Live sends that never complete — the shape of a peer on a STALE DIRECT
  /// ADDRESS. A sibling that changed networks leaves behind an endpoint that
  /// will never answer, the node keeps working its dial ladder against it, and
  /// the blocking FFI send under it comes back when it comes back. A throw is
  /// the easy failure to survive; this is the one that has cost this project
  /// outages, because nothing downstream is written to notice it.
  bool hangOnSend = false;
  final _hung = <Completer<void>>[];

  /// Let every hung send finish, so a test does not leave the machine parked
  /// mid-send for the next one.
  void releaseHungSends() {
    for (final completer in _hung) {
      if (!completer.isCompleted) completer.complete();
    }
    _hung.clear();
  }

  /// Push an inbound frame as if it arrived over the wire (the live path goes
  /// nowhere, so this is how a test simulates receiving from a NAT'd peer).
  void inject(InboundMessage m) => _inbound.add(m);

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
    if (throwOnSend) throw StateError('live route unavailable');
    if (hangOnSend) {
      final completer = Completer<void>();
      _hung.add(completer);
      await completer.future;
    }
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

/// A sink whose deposits never complete while [hang] is set — the shape of a
/// relay that silently drops a PUT and answers nothing.
class _HangingSink implements MailboxSink {
  int calls = 0;
  bool hang = true;

  @override
  bool backgroundDrainPaused = false;
  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) {
    calls++;
    if (hang) return Completer<void>().future;
    return Future.value();
  }

  @override
  void nudgeDrain() {}
  @override
  void noteActivity() {}
}

/// A sink whose every deposit fails, so the per-frame failure bookkeeping is
/// actually written.
class _FailingSink implements MailboxSink {
  int calls = 0;

  @override
  bool backgroundDrainPaused = false;

  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) {
    calls++;
    return Future<void>.error(StateError('relay refused'));
  }

  @override
  void nudgeDrain() {}

  @override
  void noteActivity() {}
}

/// Records every stash so we can assert the offline-deposit path fired.
class _RecordingSink implements MailboxSink {
  final stashed = <(NodeId, Uint8List)>[];
  int nudges = 0;

  @override
  bool backgroundDrainPaused = false;
  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async {
    stashed.add((recipient, payload));
  }

  @override
  void nudgeDrain() => nudges++;

  int activityNotes = 0;
  @override
  void noteActivity() => activityNotes++;
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

void main() {
  late NodeId a, b;
  late HiddenVolumeStorage sA;
  late MessagingService mA;
  late _BlackholeTransport tA;
  late _RecordingSink sink;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    tA = _BlackholeTransport(a);
    mA = MessagingService(tA, sA)..start();
    sink = _RecordingSink();
    mA.attachMailbox(sink);
  });

  // THE WEDGE REGRESSION (2026-08-16, live): the background deposit slot is
  // global and singular, so ONE stash that never completes froze every
  // mailbox deposit to every peer until restart — 70+ frames per sibling
  // durable and unmoving, the log an endless "another deposit is in flight".
  test('a deposit that hangs frees the slot at the deadline', () async {
    final hung = _HangingSink();
    mA.attachMailbox(hung);
    mA.mailboxStashDeadline = const Duration(milliseconds: 50);

    await mA.sendRequest(b, 'first — this one hangs');
    expect(hung.calls, 1);
    // Deadline passes; the slot must come free even though the first stash's
    // future is still pending.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    hung.hang = false;
    await mA.sendRequest(_id(3), 'second — must be admitted');
    // The retry backoff applies per-frame, not to the slot: the SECOND frame
    // has never failed and must go straight through.
    expect(hung.calls, 2, reason: 'slot freed by the deadline');
  });

  /// The failure row was dropped only on a stash SUCCESS, so a frame that
  /// failed once and was then retired — delivered live, or ACKed by the peer —
  /// kept its row for the life of the process. It stops affecting any decision
  /// after the retry window; what it goes on doing is holding memory, one
  /// entry per frame id that ever failed.
  /// A request whose deposit failed must SAY so, not look sent.
  ///
  /// Both legs of `sendRequest` had their outcome thrown away, so a request
  /// that reached neither the relay nor the peer still left the contact marked
  /// `pendingOutgoing` — which the app shows as "sent". Measured on the
  /// production network: the seal could not be made because the recipient's
  /// instance registry did not resolve, nothing was deposited, and nothing
  /// anywhere said so. This is also the one send with no retry behind it
  /// (`flushOutbox` re-stashes ACCEPTED contacts only), so the silence was
  /// permanent until somebody asked again by hand.
  test('a request whose deposit failed does not report itself sent', () async {
    mA.attachMailbox(_FailingSink());

    final deposited = await mA.sendRequest(b, 'this one goes nowhere');

    expect(
      deposited,
      isFalse,
      reason: 'the deposit threw and the caller was told it went out',
    );
  });

  /// And the message a person LOOKS at says so too.
  ///
  /// Returning the verdict was half the answer: the conversation went on
  /// showing the greeting with a sent tick beside it, which is what somebody
  /// reads a minute later, long after any snackbar. The failed mark and the
  /// "Send again" button already existed; nothing had put them on this
  /// message (report19 XV19-M1).
  test('the greeting of a failed request is marked failed', () async {
    mA.attachMailbox(_FailingSink());

    await mA.sendRequest(b, 'nothing carried this');

    final stored = await sA.loadMessages(b.hex);
    expect(stored, hasLength(1), reason: 'the greeting is kept, not dropped');
    expect(
      stored.single.status,
      MessageStatus.failed,
      reason: 'a greeting nothing carried is shown with a sent tick',
    );
    expect(stored.single.body, 'nothing carried this');
  });

  /// A retry says what happened, and a retry that lands clears the mark.
  ///
  /// `resendRequest` returned nothing at all, so the screen showed "Request
  /// sent" every time — on the one button a person presses BECAUSE the
  /// request did not get through (report19 XV19-M1).
  test('a resend reports its own verdict and clears the mark', () async {
    final failing = _FailingSink();
    mA.attachMailbox(failing);
    await mA.sendRequest(b, 'try one');
    expect(
      (await sA.loadMessages(b.hex)).single.status,
      MessageStatus.failed,
      reason: 'premise: the first attempt failed',
    );

    // Still failing: the retry must not claim otherwise.
    expect(
      await mA.resendRequest(b),
      isFalse,
      reason: 'a resend that deposited nothing answered "sent"',
    );

    // Now the relay works: the same greeting goes out under its own id and
    // the message stops being marked failed.
    mA.attachMailbox(sink);
    expect(
      await mA.resendRequest(b),
      isTrue,
      reason: 'a resend over a working relay must report the deposit',
    );
    final stored = await sA.loadMessages(b.hex);
    expect(stored, hasLength(1), reason: 'the retry re-uses the greeting');
    expect(
      stored.single.status,
      MessageStatus.sent,
      reason: 'a retry that landed left the error mark on the message',
    );
  });

  /// CONTROL: the same call over a working relay reports the deposit.
  ///
  /// Without this the assertion above is satisfied by a `sendRequest` that
  /// always answers false — which would make every request look failed and
  /// tell the user nothing.
  test('CONTROL: a request that IS deposited reports it', () async {
    final deposited = await mA.sendRequest(b, 'this one lands');

    expect(deposited, isTrue, reason: 'the recording relay stored it');
    expect(sink.stashed, isNotEmpty);
  });

  test('a retired frame leaves no bookkeeping behind', () async {
    final failing = _FailingSink();
    mA.attachMailbox(failing);

    final before = mA.mailboxTrackedFrames;
    await mA.sendRequest(b, 'this deposit fails');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      failing.calls,
      greaterThan(0),
      reason: 'the deposit has to be attempted for a failure row to exist',
    );
    expect(
      mA.mailboxTrackedFrames,
      greaterThan(before),
      reason: 'the failure is remembered, which is the point of the row',
    );

    // The peer comes back and ACKs it: the frame is retired. The durable id is
    // a UUID minted inside `sendRequest`, so it is READ from the stored copy
    // rather than guessed — the greeting is stored under the same id.
    final greeting = (await sA.loadMessages(b.hex)).single;
    mA.debugRetireOutboxFrame(b.hex, greeting.id);
    expect(
      mA.mailboxTrackedFrames,
      before,
      reason: 'a retired frame must take its bookkeeping with it',
    );
  });

  test('a connection request is deposited at the recipient mailbox', () async {
    await mA.sendRequest(b, 'hi, it is me');
    expect(sink.stashed.length, 1);
    final (recipient, payload) = sink.stashed.single;
    expect(recipient, b);
    final env = WireEnvelope.decode(payload);
    expect(env.kind, WireKind.request);
    expect(env.body, 'hi, it is me');
  });

  test('an accept is deposited at the requester mailbox', () async {
    // Simulate an inbound request from b so a has a pendingIncoming contact.
    await mA.acceptContact(b);
    expect(
      sink.stashed.any((s) {
        final env = WireEnvelope.decode(s.$2);
        return s.$1 == b && env.kind == WireKind.accept;
      }),
      isTrue,
    );
  });

  test(
    'a cloud file offer reaches the mailbox when the live send throws',
    () async {
      await sA.upsertContact(
        Contact(nodeId: b, status: ContactStatus.accepted),
      );
      final bytes = Uint8List.fromList(List.generate(300000, (i) => i % 251));
      final manifest = ContentManifest.fromBytes('cloud.bin', bytes);
      await sA.storeFile(manifest.contentId, bytes, name: manifest.name);
      await sA.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
        name: 'manifest',
      );
      tA.throwOnSend = true;

      expect(await mA.shareStoredContent(b, manifest.contentId), isTrue);

      final offer = sink.stashed.single;
      expect(offer.$1, b);
      expect(WireEnvelope.decode(offer.$2).kind, WireKind.contentManifest);
      final sent = await sA.loadMessages(b.hex);
      expect(sent.single.fileId, manifest.contentId);
    },
  );

  test(
    'a free message to an accepted contact is deposited immediately',
    () async {
      await mA.acceptContact(b); // marks b accepted on a's side
      sink.stashed.clear();
      await mA.sendText(b, 'first real message');
      expect(
        sink.stashed.any((s) {
          final env = WireEnvelope.decode(s.$2);
          return s.$1 == b &&
              env.kind == WireKind.message &&
              env.body == 'first real message';
        }),
        isTrue,
      );
    },
  );

  test('a durable ACK is deposited at the sender mailbox so a NAT-d sender '
      'stops re-sending', () async {
    await mA.acceptContact(b); // b accepted on a's side
    sink.stashed.clear();
    // b's message arrives with no live reply path (replyId 0) — exactly the
    // NAT'd case where a live-send ack can't get back. a must ACK durably AND
    // deposit it at b's mailbox so the ack reaches b over the rendezvous push,
    // flipping b's message to delivered and ending the re-send storm.
    final wire = WireEnvelope.message(
      'ping',
      id: 'm1',
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
    ).encode();
    tA.inject(
      InboundMessage(
        src: b,
        payload: wire,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    expect(
      sink.stashed.any((s) {
        final env = WireEnvelope.decode(s.$2);
        return s.$1 == b && env.kind == WireKind.ack && env.id == 'm1';
      }),
      isTrue,
      reason: 'durable ack for m1 should be deposited at b\'s mailbox',
    );
  });

  test('a file OFFER (content manifest) is deposited at the recipient mailbox '
      'so it survives a down live path like a text message does', () async {
    await mA.acceptContact(b);
    sink.stashed.clear();
    // A file above the content threshold goes through the content layer as a
    // manifest offer. Before the fix this was live-only, so on a flaky link the
    // offer vanished while texts (which stash) still arrived. The manifest
    // frame must now be deposited too, keyed by the send's msgId.
    await mA.sendFile(
      b,
      Uint8List.fromList(List.generate(200000, (i) => i & 0xff)),
      'photo.bin',
    );
    await pumpEventQueue();
    expect(
      sink.stashed.any((s) {
        final env = WireEnvelope.decode(s.$2);
        return s.$1 == b && env.kind == WireKind.contentManifest;
      }),
      isTrue,
      reason:
          'the file offer manifest should be deposited for offline delivery',
    );
  });

  test(
    'a fast-path (reply-circuit) ACK is NOT deposited — no needless traffic',
    () async {
      await mA.acceptContact(b);
      sink.stashed.clear();
      // A first receipt that carries a live reply path (replyId != 0) acks over
      // that circuit; depositing would be wasted relay traffic. Only the durable
      // path (re-receipt / no reply path) deposits.
      final wire = WireEnvelope.message(
        'ping',
        id: 'm2',
        sentAtMs: DateTime.now().millisecondsSinceEpoch,
      ).encode();
      tA.inject(
        InboundMessage(
          src: b,
          payload: wire,
          replyId: 42,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();
      expect(
        sink.stashed.any((s) => WireEnvelope.decode(s.$2).kind == WireKind.ack),
        isFalse,
        reason:
            'an ack sent over a live reply circuit must not also be stashed',
      );
    },
  );

  test(
    'a new incoming message emits on the incoming stream (notifications)',
    () async {
      await mA.acceptContact(b);
      final got = <IncomingNotice>[];
      final sub = mA.incoming.listen(got.add);
      final wire = WireEnvelope.message(
        'hey there',
        id: 'n1',
        sentAtMs: DateTime.now().millisecondsSinceEpoch,
      ).encode();
      tA.inject(
        InboundMessage(
          src: b,
          payload: wire,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();
      await sub.cancel();
      expect(got.length, 1);
      expect(got.single.from, b);
      expect(got.single.preview, 'hey there');
      expect(got.single.isFile, isFalse);
    },
  );

  test('a re-delivered (deduped) message does NOT re-emit', () async {
    await mA.acceptContact(b);
    final wire = WireEnvelope.message(
      'once',
      id: 'n2',
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
    ).encode();
    tA.inject(
      InboundMessage(
        src: b,
        payload: wire,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    // Now subscribe and re-inject the SAME id — dedup must suppress the emit.
    final got = <IncomingNotice>[];
    final sub = mA.incoming.listen(got.add);
    tA.inject(
      InboundMessage(
        src: b,
        payload: wire,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    await sub.cancel();
    expect(got, isEmpty, reason: 'a re-delivery must not re-notify');
  });

  test(
    'an ACK from a non-accepted peer cannot flip our message status',
    () async {
      await mA.acceptContact(b);
      await mA.sendText(b, 'hello');
      await pumpEventQueue();
      final sent = (await sA.loadMessages(
        b.hex,
      )).firstWhere((m) => m.body == 'hello');
      expect(sent.status, isNot(MessageStatus.delivered));

      // A stranger c (no contact, not accepted) acks our message id. The consent
      // gate must drop it — otherwise any peer could forge a delivered mark.
      final c = _id(9);
      final ack = WireEnvelope.ack(sent.id).encode();
      tA.inject(
        InboundMessage(
          src: c,
          payload: ack,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();
      expect(
        (await sA.loadMessages(
          b.hex,
        )).firstWhere((m) => m.id == sent.id).status,
        isNot(MessageStatus.delivered),
        reason: 'an unaccepted peer must not flip our delivery state',
      );

      // The real (accepted) peer b CAN ack it.
      tA.inject(
        InboundMessage(
          src: b,
          payload: ack,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();
      expect(
        (await sA.loadMessages(
          b.hex,
        )).firstWhere((m) => m.id == sent.id).status,
        MessageStatus.delivered,
      );
    },
  );

  test('an edit that drains BEFORE its message still applies (out-of-order)', () async {
    await mA.acceptContact(b);
    // The peer sent a message then edited it while we were offline. On reconnect
    // the mailbox blobs drain in arbitrary order — here the EDIT arrives first.
    // Without buffering, the edit would be dropped (its target isn't stored yet)
    // and the offline edit would silently never land.
    final edit = WireEnvelope.edit('x1', 'corrected text').encode();
    tA.inject(
      InboundMessage(
        src: b,
        payload: edit,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    // Nothing to edit yet — the op is buffered, not applied, and no ghost shows.
    expect((await sA.loadMessages(b.hex)).where((m) => m.id == 'x1'), isEmpty);

    // Now the original message arrives — the buffered edit must apply.
    final msg = WireEnvelope.message(
      'original text',
      id: 'x1',
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
    ).encode();
    tA.inject(
      InboundMessage(
        src: b,
        payload: msg,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    final stored = (await sA.loadMessages(
      b.hex,
    )).firstWhere((m) => m.id == 'x1');
    expect(
      stored.body,
      'corrected text',
      reason: 'the buffered edit must apply once its target message arrives',
    );
  });

  test(
    'a delete that drains BEFORE its message tombstones it (no resurrect)',
    () async {
      await mA.acceptContact(b);
      // The peer unsent a message while we were offline; its DEL blob drains
      // first. The message must end up unsent — order-independent deniable erase.
      final del = WireEnvelope.del('x2').encode();
      tA.inject(
        InboundMessage(
          src: b,
          payload: del,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();

      // The original arrives after the unsend — it must NOT surface.
      final msg = WireEnvelope.message(
        'secret',
        id: 'x2',
        sentAtMs: DateTime.now().millisecondsSinceEpoch,
      ).encode();
      tA.inject(
        InboundMessage(
          src: b,
          payload: msg,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();
      expect(
        await sA.isMessageDeleted(b.hex, 'x2'),
        isTrue,
        reason: 'a pre-message delete must leave a durable tombstone',
      );
      expect(
        (await sA.loadMessages(b.hex)).where((m) => m.body == 'secret'),
        isEmpty,
        reason: 'the unsent message must not surface even arriving after del',
      );

      // A re-delivery must stay refused (deleted stays deleted).
      tA.inject(
        InboundMessage(
          src: b,
          payload: msg,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();
      expect(
        (await sA.loadMessages(b.hex)).where((m) => m.body == 'secret'),
        isEmpty,
        reason: 're-delivery must not resurrect an unsent message',
      );
    },
  );

  test('a delete buffered before an edit wins (unsend is terminal)', () async {
    await mA.acceptContact(b);
    // Both a delete and a later edit drain before the message. The delete is
    // terminal: the message must stay unsent, not reappear with the edited text.
    tA.inject(
      InboundMessage(
        src: b,
        payload: WireEnvelope.del('x3').encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    tA.inject(
      InboundMessage(
        src: b,
        payload: WireEnvelope.edit('x3', 'revived?').encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    final msg = WireEnvelope.message(
      'original',
      id: 'x3',
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
    ).encode();
    tA.inject(
      InboundMessage(
        src: b,
        payload: msg,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
    await pumpEventQueue();
    expect(await sA.isMessageDeleted(b.hex, 'x3'), isTrue);
    expect(
      (await sA.loadMessages(
        b.hex,
      )).where((m) => m.id == 'x3' && m.body.isNotEmpty),
      isEmpty,
      reason: 'a buffered delete must win over a later buffered edit',
    );
  });

  test('concurrent pre-consent intros cannot race past the cap', () async {
    // A hostile peer mints a FRESH id per request and fires many AT ONCE. The
    // inbound handler is async and the stream does not await it, so without
    // serialization the per-request capPreConsentIntros (read count -> evict ->
    // store) interleaves: every concurrent frame reads the count below the cap
    // and stores, busting kMaxPreConsentIntros. Fire 40 without awaiting between
    // them, then drain — the stored intros from this unaccepted peer must never
    // exceed the cap.
    const burst = 40;
    final futures = <Future<void>>[];
    for (var i = 0; i < burst; i++) {
      final wire = WireEnvelope.request('greeting #$i', id: 'req-$i').encode();
      futures.add(
        mA.deliverInbound(
          InboundMessage(
            src: b,
            payload: wire,
            provenance: SenderProvenance.signed,
          ),
        ),
      );
    }
    await Future.wait(futures);
    await pumpEventQueue();

    final stored = await sA.loadMessages(b.hex);
    expect(
      stored.length,
      lessThanOrEqualTo(kMaxPreConsentIntros),
      reason:
          'serialized handling must hold the pre-consent cap under a '
          'concurrent burst (got ${stored.length})',
    );
  });

  test(
    'a LIVE inbound frame nudges the mailbox to drain (cut the idle-drain '
    'latency when the peer is reachable but the introduce is dropped)',
    () async {
      // A live frame over the transport proves the peer is reachable now — the
      // service must kick a drain so a message it stashed surfaces promptly
      // instead of on the ~30s idle back-off. The mailbox drain path
      // (deliverInbound) must NOT nudge (it is not the live transport).
      final wire = WireEnvelope.message(
        'hello',
        id: 'live1',
        sentAtMs: DateTime.now().millisecondsSinceEpoch,
      ).encode();
      tA.inject(
        InboundMessage(
          src: b,
          payload: wire,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue();
      expect(
        sink.nudges,
        greaterThanOrEqualTo(1),
        reason: 'a live transport frame nudges the drain',
      );

      final before = sink.nudges;
      await mA.deliverInbound(
        InboundMessage(
          src: b,
          payload: wire,
          provenance: SenderProvenance.signed,
        ),
      );
      await pumpEventQueue();
      expect(
        sink.nudges,
        before,
        reason: 'a mailbox-drained frame must NOT nudge (it is not live)',
      );
    },
  );

  test('a call offer is deposited even though the call itself paused '
      'background deposits', () async {
    // CallService sets `backgroundStashPaused` for the whole life of a call
    // (`status != ended`) so bulk sealing does not steal CPU from media. The
    // offer that STARTS the call is sent inside that window, and the deposit
    // gate used to drop it: the flush loop exempted call signals from the
    // pause, then handed them to a deposit that re-checked the pause and
    // returned.
    //
    // Measured on the stand with the live path down: nine live re-drives over
    // 75s, not one deposit, ring timeout, and the offer deposited 170ms AFTER
    // the caller had given up — so the callee rang a call that no longer
    // existed, while a plain text on the same broken path arrived in 15s.
    await mA.acceptContact(b);
    sink.stashed.clear();
    tA.throwOnSend = true; // the live leg goes nowhere, as after a node reboot
    mA.backgroundStashPaused = true; // what placing a call does

    await mA.sendDurable(
      b,
      'call:test-call-id:offer',
      WireEnvelope.callSignal(
        jsonEncode({'type': 'offer', 'callId': 'test-call-id'}),
      ),
    );
    await pumpEventQueue();

    expect(
      sink.stashed.any((s) => s.$1 == b),
      isTrue,
      reason:
          'the offer must reach the mailbox while the call is dialing — '
          'it is useless once the ring window has passed',
    );
  });

  // THE DEPOSIT MUST NOT QUEUE BEHIND A PEER THAT IS GONE (2026-08-18).
  //
  // A stale direct address is the ordinary way a peer disappears: a sibling
  // changes networks and the endpoint in its invite stops answering, while the
  // node keeps a dial ladder running against it. Reproduced on the e2e stand
  // by handing out a dial hint for a device that is then stopped — the log
  // repeats `peer.connect.failure … connection timed out after 10s`.
  //
  // Two properties, and the second is the one that turns a delay into an
  // outage: the deposit does not wait on the live leg AT ALL, and a live leg
  // that never returns does not end the pass that carries every other peer's
  // deposit.
  group('a live leg that never returns', () {
    tearDown(() => tA.releaseHungSends());

    test('does not hold up the durable copy of a durable send', () async {
      tA.hangOnSend = true;
      // Deliberately far longer than this test could ever run. It asserts the
      // ORDER, not the deadline: a deposit that arrives only when the deadline
      // fires is still a deposit that waited out a peer that is gone.
      mA.liveLegDeadline = const Duration(hours: 1);

      // Not awaited, because it cannot return — the live leg is the black
      // hole. That is the whole point: the caller is stuck and the mailbox
      // copy must be safe anyway.
      unawaited(mA.sendRequest(b, 'the live leg is a black hole'));
      await pumpEventQueue(times: 50);

      expect(
        sink.stashed.length,
        1,
        reason:
            'the relay copy is the one that survives the peer being gone, so '
            'it cannot be sequenced behind an attempt to reach it — and the '
            'sequencing bought nothing, since the deposit happens whether the '
            'live leg succeeds or fails',
      );
      expect(sink.stashed.single.$1, b);
    });

    /// An un-acked message to a peer that has stopped answering, which is what
    /// a retry pass is for and the exact state case 10 leaves A in.
    Future<void> unackedMessageToB() async {
      await mA.acceptContact(b);
      tA.hangOnSend = true;
      unawaited(mA.sendText(b, 'sent while the peer was already gone'));
      await pumpEventQueue(times: 50);
      sink.stashed.clear();
    }

    test('does not stop the retry pass', () async {
      await unackedMessageToB();
      mA.liveLegDeadline = const Duration(milliseconds: 50);

      // THE PASS MUST END. `_retryFlush` runs one at a time behind a
      // `_flushing` flag, so a pass that never returns is not a slow pass —
      // it is the last one this process runs, and every mailbox deposit to
      // every peer stops with it. Same shape as the deposit slot that one
      // stuck PUT froze for 10+ minutes in 2026-08-16; that half got a
      // deadline and this half did not.
      await mA.flushOutbox().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the retry pass never ended — one unreachable peer has taken '
          'the flush that carries every peer\'s deposit with it',
        ),
      );
    });

    test('does not hold up the deposit the retry pass owes', () async {
      await unackedMessageToB();
      // Long on purpose, so the deadline above cannot be what rescues this:
      // a deposit that only lands when the live leg is abandoned is still a
      // deposit that waited out a peer that is gone.
      mA.liveLegDeadline = const Duration(seconds: 30);

      unawaited(mA.flushOutbox());
      await pumpEventQueue(times: 50);

      expect(
        sink.stashed.any((s) => s.$1 == b),
        isTrue,
        reason:
            'the retry runs BECAUSE the message is un-acked, so the peer is by '
            'definition the one we have failed to reach — the deposit belongs '
            'in front of the next attempt to reach it, not behind it',
      );
    });

    test('does not hold up the durable ACK owed to the sender', () async {
      await mA.acceptContact(b);
      sink.stashed.clear();
      tA.hangOnSend = true;
      mA.liveLegDeadline = const Duration(hours: 1);

      // No reply circuit (replyId 0), so this is the durable ack path — the
      // one that exists because the sender cannot be reached live. A sender
      // left un-acked re-sends forever, which is the storm the deposit ends.
      tA.inject(
        InboundMessage(
          src: b,
          payload: WireEnvelope.message(
            'ping',
            id: 'ack-order',
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
          ).encode(),
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await pumpEventQueue(times: 50);

      expect(
        sink.stashed.any((s) {
          final env = WireEnvelope.decode(s.$2);
          return s.$1 == b && env.kind == WireKind.ack && env.id == 'ack-order';
        }),
        isTrue,
        reason:
            'the ack rides the mailbox BECAUSE the sender is unreachable live; '
            'waiting for the live leg first is waiting for the very thing the '
            'deposit is standing in for',
      );
    });

    test('does not delay ANOTHER peer\'s deposit in the same pass', () async {
      final c = _id(3);
      await mA.acceptContact(b);
      await mA.acceptContact(c);
      sink.stashed.clear();
      // Straight into the store, which is how a restart finds them: no live
      // backoff has been recorded yet, so this pass dials both. One flat list
      // used to interleave the two halves — b's dial stood in front of c's
      // DEPOSIT, and b is the peer that cannot be reached.
      await sA.enqueueOutboxFrame(
        'frame-for-b',
        b.hex,
        WireEnvelope.message('to b', id: 'frame-for-b', sentAtMs: 0).encode(),
      );
      await sA.enqueueOutboxFrame(
        'frame-for-c',
        c.hex,
        WireEnvelope.message('to c', id: 'frame-for-c', sentAtMs: 0).encode(),
      );
      tA.hangOnSend = true;
      // Long enough that a deposit which waited for the dial cannot sneak in
      // under the pump below and pass by accident.
      mA.liveLegDeadline = const Duration(seconds: 30);

      unawaited(mA.debugFlushOutboxFrames());
      await pumpEventQueue(times: 50);

      expect(
        sink.stashed.map((s) => s.$1).toSet(),
        {b, c},
        reason:
            'every frame in a pass is offered to the deposit gate before any '
            'of them is dialled, so an unreachable destination costs the live '
            'half of the pass and nothing else',
      );
    });
  });

  test('ordinary traffic still yields to a call', () async {
    // The exemption above is for call control only. A plain message sent while
    // a call is up must still wait for the outbox flush rather than seal and
    // fan out against the media path — that is what the pause is for.
    await mA.acceptContact(b);
    sink.stashed.clear();
    mA.backgroundStashPaused = true;

    await mA.sendText(b, 'not urgent');
    await pumpEventQueue();

    expect(
      sink.stashed,
      isEmpty,
      reason:
          'a chat message must not deposit while a call has paused deposits',
    );
  });
}
