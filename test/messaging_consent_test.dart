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
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/domain/space_recommendation.dart';
import 'package:xveil/domain/space_join_request.dart';
import 'package:xveil/domain/space_public_feed_transport.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// Direct 1:1 fake link: send() delivers to the peer's inbound, tagged with
/// our node id as the source.
class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final List<Uint8List> sentPayloads = <Uint8List>[];
  _FakeTransport? peer;

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
    sentPayloads.add(Uint8List.fromList(payload));
    peer?._inbound.add(
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
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

String _joinCode(NodeId space, NodeId approver, String ticketId) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return SpaceJoinCode.encode(
    SpaceJoinTicket(
      ticketId: ticketId,
      spaceId: space,
      approver: approver,
      spaceName: 'Public lab',
      createdAtMs: now,
      expiresAtMs: now + const Duration(days: 7).inMilliseconds,
    ),
  );
}

void main() {
  late NodeId a, b;
  late _FakeTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _FakeTransport(a);
    tB = _FakeTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_memOpener());
    sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    mA = MessagingService(tA, sA)..start();
    mB = MessagingService(tB, sB)..start();
  });

  test(
    'request -> accept -> message; gating blocks pre-accept and strangers',
    () async {
      // A requests B with a greeting.
      await mA.sendRequest(b, 'hi, can we connect?');
      await _pump();
      expect((await sA.getContact(b))!.status, ContactStatus.pendingOutgoing);
      expect((await sB.getContact(a))!.status, ContactStatus.pendingIncoming);
      expect((await sB.loadMessages(a.hex)).single.body, 'hi, can we connect?');

      // A cannot free-message before B accepts.
      await mA.sendText(b, 'let me in');
      await _pump();
      expect((await sB.loadMessages(a.hex)).length, 1); // greeting only

      // B accepts -> both accepted.
      await mB.acceptContact(a);
      await _pump();
      expect((await sB.getContact(a))!.status, ContactStatus.accepted);
      expect((await sA.getContact(b))!.status, ContactStatus.accepted);

      // Now free messaging works both ways.
      await mA.sendText(b, 'hello');
      await _pump();
      expect(
        (await sB.loadMessages(a.hex)).map((m) => m.body),
        contains('hello'),
      );
    },
  );

  test('a plain message from a stranger is dropped (no auto-add)', () async {
    // B never requested/accepted A; A sends a raw message.
    await mA.sendText(b, 'spam'); // gated on A's side anyway (no contact)
    // Force a bare message even without a contact:
    await tA.send(b, const WireEnvelopeMessage('hi stranger').bytes);
    await _pump();
    expect(await sB.getContact(a), isNull);
    expect(await sB.loadMessages(a.hex), isEmpty);
  });

  test('recommendation card is consent-gated, typed and persisted', () async {
    final card = SpaceRecommendationCard(
      campaignId: 'ab' * 32,
      spaceId: _id(8),
      name: 'Public lab',
      description: 'Open community',
      text: 'Take a look',
      joinCode: _joinCode(_id(8), a, '11' * 32),
    );
    expect(await mA.sendSpaceRecommendation(b, card), isNull);

    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    expect(await mA.sendSpaceRecommendation(b, card), isNotNull);
    await _pump();

    final incoming = (await sB.loadMessages(a.hex)).where(
      (message) => parseSpaceRecommendationMessage(message.body) != null,
    );
    expect(incoming, hasLength(1));
    expect(
      parseSpaceRecommendationMessage(incoming.single.body)?.campaignId,
      card.campaignId,
    );
  });

  test('plain text and edit APIs cannot forge or rewrite a card', () async {
    final card = SpaceRecommendationCard(
      campaignId: 'bc' * 32,
      spaceId: _id(8),
      name: 'Public lab',
      description: 'Open community',
      text: 'Take a look',
      joinCode: _joinCode(_id(8), a, '12' * 32),
    );
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();

    final marker = encodeSpaceRecommendationMessage(card);
    await mA.sendText(b, marker);
    await tA.send(
      b,
      WireEnvelope.message(marker, id: 'smuggled-card').encode(),
    );
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).where(
        (message) => parseSpaceRecommendationMessage(message.body) != null,
      ),
      isEmpty,
    );

    expect(await mA.sendSpaceRecommendation(b, card), isNotNull);
    await _pump();
    final outgoing = (await sA.loadMessages(b.hex)).singleWhere(
      (message) => parseSpaceRecommendationMessage(message.body) != null,
    );
    await mA.editOwnMessage(outgoing.id, 'rewritten');
    expect(
      parseSpaceRecommendationMessage(
        (await sA.loadMessages(
          b.hex,
        )).singleWhere((message) => message.id == outgoing.id).body,
      )?.text,
      card.text,
    );
  });

  test('typed recommendation revocation removes exactly that card', () async {
    final card = SpaceRecommendationCard(
      campaignId: 'bd' * 32,
      spaceId: _id(8),
      name: 'Public lab',
      description: '',
      text: 'Take a look',
      joinCode: _joinCode(_id(8), a, '13' * 32),
    );
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();

    final messageId = await mA.sendSpaceRecommendation(b, card);
    expect(messageId, isNotNull);
    await _pump();
    expect(await mA.revokeSpaceRecommendation(b, messageId!), isTrue);
    await _pump();
    expect(
      (await sA.loadMessages(
        b.hex,
      )).where((message) => message.id == messageId),
      isEmpty,
    );
    expect(
      (await sB.loadMessages(
        a.hex,
      )).where((message) => message.id == messageId),
      isEmpty,
    );
    expect(await mA.revokeSpaceRecommendation(b, 'ordinary-message'), isFalse);
  });

  test('recommendation receiver opt-out silently discards the card', () async {
    final card = SpaceRecommendationCard(
      campaignId: 'cd' * 32,
      spaceId: _id(8),
      name: 'Public lab',
      description: '',
      text: 'Take a look',
      joinCode: _joinCode(_id(8), a, '22' * 32),
    );
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    await mB.setSpaceRecommendationsEnabled(false);
    expect(
      (await mB.spaceRecommendationRecipientPolicy()).mode,
      SpaceRecommendationRecipientMode.blockAll,
    );
    expect(
      await sB.getSetting('privacy.space_recommendations.enabled.v1'),
      contains('"mode":"blockAll"'),
    );

    expect(await mA.sendSpaceRecommendation(b, card), isNotNull);
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).where(
        (message) => parseSpaceRecommendationMessage(message.body) != null,
      ),
      isEmpty,
    );
  });

  test('recommendation with a forged join capability is dropped', () async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    final forged = SpaceRecommendationCard(
      campaignId: 'ef' * 32,
      spaceId: _id(8),
      name: 'Forged',
      description: '',
      text: 'Click me',
      joinCode: 'xveil://space/v1#not-a-capability',
    );
    await tA.send(
      b,
      WireEnvelope.spaceRecommendation(forged, id: 'forged-card').encode(),
    );
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).where(
        (message) => parseSpaceRecommendationMessage(message.body) != null,
      ),
      isEmpty,
    );
  });

  test(
    'a message carries its seq; both devices fold under the same (author,seq)',
    () async {
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();
      await mA.sendText(b, 'one');
      await _pump();
      await mA.sendText(b, 'two');
      await _pump();

      final aMsgs = {for (final m in await sA.loadMessages(b.hex)) m.body: m};
      final bMsgs = {for (final m in await sB.loadMessages(a.hex)) m.body: m};
      // The sender's (author, seq) travels on the wire, so the receiver stores the
      // SAME identity — the basis for a convergent log + gap detection.
      for (final body in ['one', 'two']) {
        expect(
          bMsgs[body]!.author,
          aMsgs[body]!.author,
          reason: 'author identical on both devices ($body)',
        );
        expect(
          bMsgs[body]!.seq,
          aMsgs[body]!.seq,
          reason: 'seq identical on both devices ($body)',
        );
      }
      // Author is A's own node id on both sides (R1 — not inferred from direction).
      expect(aMsgs['one']!.author, a.hex);
      expect(bMsgs['one']!.author, a.hex);
    },
  );

  test('blocking drops subsequent messages', () async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    await mB.blockContact(a);
    await mA.sendText(b, 'after block');
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).any((m) => m.body == 'after block'),
      isFalse,
    );
  });

  test('unblocking restores delivery', () async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
    await mB.blockContact(a);
    await mA.sendText(b, 'while blocked');
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).any((m) => m.body == 'while blocked'),
      isFalse,
    );

    // Lift the block — the contact is accepted again and new messages deliver.
    await mB.unblockContact(a);
    expect((await sB.getContact(a))!.status, ContactStatus.accepted);
    await mA.sendText(b, 'after unblock');
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).any((m) => m.body == 'after unblock'),
      isTrue,
      reason: 'unblock restores accepted status so messages flow again',
    );
  });

  test(
    'a local contact alias is set, trimmed, cleared — never sent on the wire',
    () async {
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();

      // A names B locally; the alias is trimmed and becomes the display label.
      await mA.setContactName(b, '  Alice  ');
      expect((await sA.getContact(b))!.name, 'Alice');
      expect((await sA.getContact(b))!.label, 'Alice');

      // B never learns the alias — it is local-only, nothing went on the wire.
      await _pump();
      expect((await sB.getContact(a))?.name, isNull);

      // Blank input clears it back to the node-id label.
      await mA.setContactName(b, '   ');
      expect((await sA.getContact(b))!.name, isNull);
      expect((await sA.getContact(b))!.label, b.short);
    },
  );

  test('chat folders: create, multi-membership, move, delete', () async {
    final b2 = NodeId.fromHex('03' * 32);
    // Two folders.
    final work = await mA.createFolder('Work');
    final fam = await mA.createFolder('Family');
    expect((await mA.loadFolders()).length, 2);

    // b is in BOTH folders (multi-membership); b2 only in Family.
    await mA.setFolderMembership(work.id, b.hex, true);
    await mA.setFolderMembership(fam.id, b.hex, true);
    await mA.setFolderMembership(fam.id, b2.hex, true);
    var folders = await mA.loadFolders();
    expect(folders.firstWhere((f) => f.id == work.id).memberHexes, [b.hex]);
    expect(
      folders.firstWhere((f) => f.id == fam.id).memberHexes,
      containsAll([b.hex, b2.hex]),
    );

    // Move b out of Work (idempotent remove).
    await mA.setFolderMembership(work.id, b.hex, false);
    folders = await mA.loadFolders();
    expect(folders.firstWhere((f) => f.id == work.id).contains(b.hex), isFalse);
    expect(folders.firstWhere((f) => f.id == fam.id).contains(b.hex), isTrue);

    // Rename + delete.
    await mA.renameFolder(fam.id, 'Kin');
    expect(
      (await mA.loadFolders()).firstWhere((f) => f.id == fam.id).name,
      'Kin',
    );
    await mA.deleteFolder(work.id);
    final left = await mA.loadFolders();
    expect(left.length, 1);
    expect(left.single.id, fam.id);
  });

  test('forbidding peer-delete makes their unsend keep our copy', () async {
    // A and B become mutual contacts.
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();

    // A sends B a message; B holds it.
    await mA.sendText(b, 'keep me');
    await _pump();
    final held = (await sB.loadMessages(
      a.hex,
    )).firstWhere((m) => m.body == 'keep me');

    // B forbids A from deleting at B (default is allow).
    expect((await sB.getContact(a))!.allowPeerDelete, isTrue);
    await mB.setContactAllowPeerDelete(a, false);
    expect((await sB.getContact(a))!.allowPeerDelete, isFalse);

    // A unsends it for everyone — B's copy must SURVIVE (policy declines it).
    await mA.deleteForEveryone(held.id);
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).any((m) => m.body == 'keep me'),
      isTrue,
      reason: 'a forbidden contact cannot delete at us',
    );

    // Re-allow, send + delete another: now it IS removed (default behavior).
    await mB.setContactAllowPeerDelete(a, true);
    await mA.sendText(b, 'delete me');
    await _pump();
    final del2 = (await sB.loadMessages(
      a.hex,
    )).firstWhere((m) => m.body == 'delete me');
    await mA.deleteForEveryone(del2.id);
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).any((m) => m.body == 'delete me'),
      isFalse,
      reason: 'an allowed contact deletes at us as before',
    );
  });

  test(
    'per-contact P2P override persists without clobbering other policies',
    () async {
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();

      await mB.setContactAllowPeerDelete(a, false);
      await mB.setContactP2POverride(a, ContactP2POverride.allow);
      var contact = (await sB.getContact(a))!;
      expect(contact.p2pOverride, ContactP2POverride.allow);
      expect(
        contact.allowPeerDelete,
        isFalse,
        reason: 'saving P2P override must not reset peer-delete policy',
      );

      await mB.setContactRetention(a, 30);
      contact = (await sB.getContact(a))!;
      expect(contact.retentionDays, 30);
      expect(
        contact.p2pOverride,
        ContactP2POverride.allow,
        reason: 'saving retention must not reset P2P override',
      );
      expect(contact.allowPeerDelete, isFalse);
    },
  );

  test(
    'muting a contact persists, survives a rename, and is local-only',
    () async {
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();

      expect((await sA.getContact(b))!.muted, isFalse); // default
      await mA.setContactMuted(b, true);
      expect((await sA.getContact(b))!.muted, isTrue);

      // A later rename must preserve the mute flag (setContactName rebuilds the
      // record directly, so it has to carry muted across).
      await mA.setContactName(b, 'B');
      final c = await sA.getContact(b);
      expect(c!.muted, isTrue);
      expect(c.name, 'B');

      await mA.setContactMuted(b, false);
      expect((await sA.getContact(b))!.muted, isFalse);

      // B never sees A's mute — it is purely local.
      expect((await sB.getContact(a))?.muted ?? false, isFalse);
    },
  );

  test('pre-consent intro spam is capped, keeping the most recent', () async {
    // A hostile peer mints a FRESH id per request so the dedup-by-id path does
    // not collapse them. Without the cap these pile up unbounded before B ever
    // accepts; with it, B holds at most kMaxPreConsentIntros (the most recent).
    const total = kMaxPreConsentIntros + 4;
    for (var i = 0; i < total; i++) {
      // distinct ids => not an overwrite; the _pump spaces timestamps by ms so
      // eviction order (oldest-first) is deterministic.
      await tA.send(b, WireEnvelope.request('intro $i', id: 'req-$i').encode());
      await _pump();
    }

    final msgs = await sB.loadMessages(a.hex);
    expect(
      msgs.length,
      kMaxPreConsentIntros,
      reason: 'pre-consent intros must be bounded to the cap',
    );
    final bodies = msgs.map((m) => m.body).toSet();
    for (var i = 0; i < total; i++) {
      final survived = i >= total - kMaxPreConsentIntros; // most recent N kept
      expect(
        bodies.contains('intro $i'),
        survived,
        reason: 'intro $i ${survived ? "must survive" : "must be evicted"}',
      );
    }
    // The peer is still pending — the cap is anti-spam, not a consent change.
    expect((await sB.getContact(a))!.status, ContactStatus.pendingIncoming);
  });

  test(
    'a same-id re-request overwrites in place and does not consume the cap',
    () async {
      // Re-sending the SAME request id (e.g. an outbox retry) must overwrite, not
      // accumulate, and must never evict — so a legit single intro is preserved.
      for (var i = 0; i < 3; i++) {
        await tA.send(
          b,
          WireEnvelope.request('intro v$i', id: 'same').encode(),
        );
        await _pump();
      }
      final msgs = await sB.loadMessages(a.hex);
      expect(msgs.length, 1, reason: 'same id => one stored copy');
      expect(msgs.single.body, 'intro v2', reason: 'last write wins');
    },
  );

  test(
    'a re-request never evicts an accepted peer\'s real conversation',
    () async {
      // Guard: the cap counts incoming messages, which for an accepted peer
      // includes real chat. A later re-request must NOT evict that history.
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();
      for (var i = 0; i < kMaxPreConsentIntros + 3; i++) {
        await mA.sendText(b, 'msg $i');
        await _pump();
      }
      final before = (await sB.loadMessages(a.hex)).length;
      expect(before, greaterThan(kMaxPreConsentIntros));

      // A reconnects and re-sends a request (some clients do on resume).
      await tA.send(b, WireEnvelope.request('re-hi', id: 'rereq').encode());
      await _pump();

      final after = await sB.loadMessages(a.hex);
      expect(
        after.length,
        greaterThanOrEqualTo(before),
        reason: 'an accepted peer\'s history is never evicted by a re-request',
      );
      expect(
        after.any((m) => m.body == 'msg 0'),
        isTrue,
        reason: 'the oldest real message must survive',
      );
    },
  );

  test(
    'public feed object frames cross the contact boundary without chat or ACK',
    () async {
      final requestSeen = Completer<(NodeId, String)>();
      final chunkSeen = Completer<(NodeId, String)>();
      mB.onSpacePublicFeedRequest = (peer, body) async {
        if (!requestSeen.isCompleted) requestSeen.complete((peer, body));
      };
      mA.onSpacePublicFeedChunk = (peer, body) {
        if (!chunkSeen.isCompleted) chunkSeen.complete((peer, body));
      };

      const request = '{"kind":"request","nonce":"aa"}';
      const chunk = '{"kind":"chunk","nonce":"aa","index":0}';
      await mA.sendSpacePublicFeedRequest(b, request);
      expect(await requestSeen.future.timeout(const Duration(seconds: 2)), (
        a,
        request,
      ));
      await mB.sendSpacePublicFeedChunk(a, chunk);
      expect(await chunkSeen.future.timeout(const Duration(seconds: 2)), (
        b,
        chunk,
      ));
      await _pump();

      expect(await sA.getContact(b), isNull);
      expect(await sB.getContact(a), isNull);
      expect(await sA.loadMessages(b.hex), isEmpty);
      expect(await sB.loadMessages(a.hex), isEmpty);
      expect(await sA.pendingOutboxFrames(), isEmpty);
      expect(await sB.pendingOutboxFrames(), isEmpty);
    },
  );

  test(
    'public media grant request is live-only and creates no contact or chat',
    () async {
      final seen = Completer<(NodeId, String)>();
      mB.onSpacePublicMediaGrantRequest = (peer, body) async {
        if (!seen.isCompleted) seen.complete((peer, body));
      };
      final request = SpacePublicMediaGrantRequest(
        spaceId: _id(3),
        descriptorHash: '11' * 32,
        manifestHash: '22' * 32,
        contentId: '33' * 32,
        requester: a,
        requesterPublicKey: a.bytes,
        nonce: '44' * 32,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        signature: Uint8List(64),
      );
      final body = jsonEncode(request.toJson());

      await mA.sendSpacePublicMediaGrantRequest(b, body);
      expect(await seen.future.timeout(const Duration(seconds: 2)), (a, body));
      await _pump();

      expect(await sA.getContact(b), isNull);
      expect(await sB.getContact(a), isNull);
      expect(await sA.loadMessages(b.hex), isEmpty);
      expect(await sB.loadMessages(a.hex), isEmpty);
      expect(await sA.pendingOutboxFrames(), isEmpty);
      expect(await sB.pendingOutboxFrames(), isEmpty);
    },
  );

  test('live-only public frames never ACK an injected frame id', () async {
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
    final seen = Completer<void>();
    mB.onSpacePublicMediaGrantRequest = (_, _) async {
      if (!seen.isCompleted) seen.complete();
    };

    await tA.send(
      b,
      const WireEnvelope.spacePublicMediaGrantRequest(
        '{"kind":"live-only"}',
      ).withFrameId('must-not-ack').encode(),
    );
    await seen.future.timeout(const Duration(seconds: 2));
    await _pump();

    expect(
      tB.sentPayloads.map(WireEnvelope.decode).map((env) => env.kind),
      isNot(contains(WireKind.ack)),
    );
    expect(await sB.loadMessages(a.hex), isEmpty);
  });
}

/// Tiny helper to craft a raw message payload in the stranger test.
class WireEnvelopeMessage {
  const WireEnvelopeMessage(this.text);
  final String text;
  Uint8List get bytes => Uint8List.fromList('{"t":2,"b":"$text"}'.codeUnits);
}
