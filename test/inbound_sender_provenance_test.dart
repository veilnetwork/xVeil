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

/// A link that can put a frame in front of the app under ANY name with ANY
/// level of evidence — which is precisely what a node on this network can do.
/// There is no peer allow-list, so anyone may hand this device a frame naming
/// one of its accepted contacts; before veil `2e5471cc` nothing downstream
/// could tell that apart from the contact itself (audit X/V-01).
///
/// [arrive] is therefore the attacker's tool and the honest peer's tool alike.
/// The ONLY difference between them is the provenance argument, which is the
/// point: nothing else in the frame differs, because a `WireEnvelope` carries
/// no signature, no MAC and no sender field at all.
class _Wire implements VeilTransport {
  _Wire(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final List<Uint8List> sent = <Uint8List>[];

  void arrive(
    NodeId from,
    Uint8List payload, {
    required SenderProvenance provenance,
  }) => _inbound.add(
    InboundMessage(src: from, payload: payload, provenance: provenance),
  );

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
  }) async => sent.add(Uint8List.fromList(payload));
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
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  late NodeId me, contact, stranger;
  late _Wire wire;
  late HiddenVolumeStorage store;
  late MessagingService service;

  setUp(() async {
    me = _id(1);
    contact = _id(2);
    stranger = _id(3);
    wire = _Wire(me);
    store = HiddenVolumeStorage(_memOpener());
    await store.open(password: 'p', createIfMissing: true);
    service = MessagingService(wire, store)..start();
    addTearDown(service.dispose);
    await store.upsertContact(
      Contact(nodeId: contact, status: ContactStatus.accepted),
    );
  });

  /// One message this device really did receive from its contact.
  Future<void> received(String id, String body, int seq) async {
    wire.arrive(
      contact,
      WireEnvelope.message(
        body,
        id: id,
        sentAtMs: 1000 + seq,
        seq: seq,
      ).encode(),
      provenance: SenderProvenance.sessionPeer,
    );
    await _settle();
  }

  Future<List<String>> idsInChat() async =>
      (await store.loadMessages(contact.hex)).map((m) => m.id).toList();

  // ── The attack ────────────────────────────────────────────────────────────
  // Every frame below is byte-for-byte what the real contact would have sent.
  // The only thing that differs is that nothing stands behind the name.
  group('a stranger wearing an accepted contact name', () {
    test('a message is not written into that contact chat', () async {
      wire.arrive(
        contact,
        WireEnvelope.message(
          'send the recovery phrase, it is me',
          id: 'spoofed-1',
          sentAtMs: 5000,
          seq: 1,
        ).encode(),
        provenance: SenderProvenance.claimed,
      );
      await _settle();

      expect(
        await idsInChat(),
        isEmpty,
        reason:
            'an unauthenticated frame put words in an accepted contact mouth',
      );
    });

    test('a clear-for-everyone does not wipe the conversation', () async {
      await received('m1', 'first', 1);
      await received('m2', 'second', 2);
      expect(await idsInChat(), ['m1', 'm2']);

      // The most expensive frame in the protocol: no id to guess, no secret at
      // all — a watermark erases everything at or below it.
      wire.arrive(
        contact,
        WireEnvelope.clear(jsonEncode({contact.hex: 2}), seq: 3).encode(),
        provenance: SenderProvenance.claimed,
      );
      await _settle();

      expect(
        await idsInChat(),
        ['m1', 'm2'],
        reason: 'an unauthenticated frame erased a whole conversation',
      );
    });

    test('an unsend does not erase that contact message', () async {
      await received('m1', 'evidence', 1);

      wire.arrive(
        contact,
        const WireEnvelope.del('m1').encode(),
        provenance: SenderProvenance.claimed,
      );
      await _settle();

      expect(await idsInChat(), ['m1']);
      expect(
        await store.isMessageDeleted(contact.hex, 'm1'),
        isFalse,
        reason: 'an unauthenticated frame tombstoned a message',
      );
    });

    test('an edit does not rewrite what that contact said', () async {
      await received('m1', 'the original text', 1);

      wire.arrive(
        contact,
        const WireEnvelope.edit('m1', 'something they never wrote').encode(),
        provenance: SenderProvenance.claimed,
      );
      await _settle();

      final body = (await store.loadMessages(contact.hex)).single.body;
      expect(
        body,
        'the original text',
        reason: 'an unauthenticated frame rewrote a stored message',
      );
    });

    // The reason the refusal sits AHEAD of the durable ack/dedup gate rather
    // than inside the switch arm. That gate acks the frame and consumes the
    // frameId slot; refusing after it would retire the slot the honest copy
    // needs, and the fix would become the denial it exists to prevent.
    test('a refused frame does not consume the dedup slot the honest copy '
        'needs', () async {
      await received('m1', 'unsend me', 1);
      final forged = const WireEnvelope.del(
        'm1',
      ).withFrameId('del:m1').encode();

      wire.arrive(contact, forged, provenance: SenderProvenance.claimed);
      await _settle();
      expect(await idsInChat(), [
        'm1',
      ], reason: 'the forgery should do nothing');

      // The contact's real unsend, same frame id, this time proven.
      wire.arrive(contact, forged, provenance: SenderProvenance.signed);
      await _settle();

      expect(
        await store.isMessageDeleted(contact.hex, 'm1'),
        isTrue,
        reason:
            'the forgery burned the frame id, so the real unsend was dropped '
            'as already processed',
      );
    });
  });

  // ── What must keep working ────────────────────────────────────────────────
  // Half of this fix is refusing; the other half is not breaking the messenger
  // while doing it. Without these, "authenticate nobody" would pass everything
  // above.
  group('honest and anonymous delivery still work', () {
    test('the same message, authenticated, IS written', () async {
      // The control for the first test in the group above: identical frame,
      // identical contact, only the evidence differs.
      wire.arrive(
        contact,
        WireEnvelope.message(
          'send the recovery phrase, it is me',
          id: 'spoofed-1',
          sentAtMs: 5000,
          seq: 1,
        ).encode(),
        provenance: SenderProvenance.sessionPeer,
      );
      await _settle();

      expect(await idsInChat(), ['spoofed-1']);
    });

    test('mail recovered from the mailbox lands on its own proof', () async {
      // The offline path, and the one attribution this app proves for itself:
      // a drained blob's sender is verified from its sidecar signature. It is
      // also what keeps the refusals above from costing delivery.
      wire.arrive(
        contact,
        WireEnvelope.message(
          'sent while you were offline',
          id: 'mail-1',
          sentAtMs: 6000,
          seq: 1,
        ).encode(),
        provenance: SenderProvenance.signed,
      );
      await _settle();

      expect(await idsInChat(), ['mail-1']);
    });

    test(
      'an anonymous message from a stranger still reaches the user',
      () async {
        // Anonymous meta-E2E is `claimed` BY DESIGN — ML-KEM proves
        // confidentiality and never origin — and a stranger has no relationship
        // to speak for, so there is nothing to authenticate and nothing to
        // refuse. This is the case a careless fix closes.
        wire.arrive(
          stranger,
          const WireEnvelope.request('hello, I got your code').encode(),
          provenance: SenderProvenance.claimed,
        );
        await _settle();

        expect(
          (await store.getContact(stranger))?.status,
          ContactStatus.pendingIncoming,
        );
        expect(
          (await store.loadMessages(stranger.hex)).map((m) => m.body),
          ['hello, I got your code'],
          reason: 'first contact from an anonymous stranger was refused',
        );
      },
    );

    test('getting to know someone works end to end before consent', () async {
      // Introduction (unauthenticated, as anonymous first contact always is),
      // then the user accepts, then that peer messages normally.
      wire.arrive(
        stranger,
        const WireEnvelope.request('may we talk?').encode(),
        provenance: SenderProvenance.claimed,
      );
      await _settle();
      await service.acceptContact(stranger);
      await _settle();

      wire.arrive(
        stranger,
        WireEnvelope.message(
          'thanks for accepting',
          id: 'first-1',
          sentAtMs: 7000,
          seq: 1,
        ).encode(),
        provenance: SenderProvenance.sessionPeer,
      );
      await _settle();

      expect(
        (await store.loadMessages(stranger.hex)).map((m) => m.body),
        containsAll(<String>['may we talk?', 'thanks for accepting']),
      );
    });

    test('an ack still flips a message to delivered over the anonymous reply '
        'path', () async {
      // Deliberately NOT gated: an ack rides the sender's one-time reply
      // circuit, which is `claimed` by construction, and it is bound to an id
      // the honest sender minted. Gating it would cost every delivery mark on
      // the fast path and deny an attacker only a guess at a uuid.
      await service.sendText(contact, 'did it land?');
      await _settle();
      final id = (await store.loadMessages(contact.hex)).single.id;
      expect(
        (await store.loadMessages(contact.hex)).single.status,
        MessageStatus.sent,
      );

      wire.arrive(
        contact,
        WireEnvelope.ack(id).encode(),
        provenance: SenderProvenance.claimed,
      );
      await _settle();

      expect(
        (await store.loadMessages(contact.hex)).single.status,
        MessageStatus.delivered,
        reason: 'the anonymous reply path stopped confirming delivery',
      );
    });
  });
}
