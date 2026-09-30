part of 'messaging_core.dart';

typedef _HeldBlockedMessage = ({String id, String wire, int? receivedAtMs});

/// Contact consent and relationship lifecycle.
///
/// Owns request/reconnect handling, pre-consent anti-spam bounds, local and
/// mirrored status transitions, and the user-facing relationship actions.
class _MessagingContacts {
  _MessagingContacts(this._owner);

  final MessagingService _owner;

  /// Bound the number of pre-consent intro messages held from a single
  /// not-yet-accepted [peer] (anti-spam). Each [WireKind.request] greeting is
  /// stored so the consent prompt can show it; before acceptance the only
  /// incoming messages from a peer ARE these intros (real messages are gated on
  /// `accepted`), so capping incoming-count == capping intros. We evict the
  /// oldest so that, after storing the new intro [newId], we retain at most
  /// [kMaxPreConsentIntros]. No-op for an accepted peer (we must never evict a
  /// real conversation) or a same-id re-send (it overwrites in place, not a new
  /// intro). Evicted bodies are scrubbed so they leave no recoverable trace.
  Future<void> capPreConsentIntros(NodeId peer, String? newId) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact?.status == ContactStatus.accepted) return;
    final msgs = await _owner._storage.loadMessages(peer.hex);
    if (newId != null && msgs.any((m) => m.id == newId)) return; // overwrite
    final intros =
        msgs.where((m) => m.direction == MessageDirection.incoming).toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Make room for the one we're about to add: keep at most cap-1 of the old.
    final evict = intros.length - (kMaxPreConsentIntros - 1);
    if (evict <= 0) return;
    for (var i = 0; i < evict; i++) {
      await _owner._storage.deleteMessage(peer.hex, intros[i].id);
    }
    await _owner._storage.scrubDeleted();
  }

  Future<void> setStatus(NodeId peer, ContactStatus status) async {
    final existing = await _owner._storage.getContact(peer);
    await _owner._storage.upsertContact(
      (existing ?? Contact(nodeId: peer)).copyWith(status: status),
    );
    if (status == ContactStatus.accepted) {
      _owner._realtimeControl.markAccepted(peer);
    } else {
      _owner._realtimeControl.revoke(peer);
    }
    _owner.onContactStatusChanged?.call(peer, status);
  }

  /// Apply a relationship status mirrored from ANOTHER of my devices. Unlike
  /// the preference mirror this CREATES a missing contact (that is the
  /// contact-list sync: an add/accept/block decided on my other device is the
  /// same owner's decision), preserving every other field of an existing
  /// record. Writes straight to storage — never re-fires
  /// [_owner.onContactStatusChanged], so a mirrored status cannot echo.
  Future<bool> applyMirroredContactStatus(
    NodeId peer,
    ContactStatus status,
  ) async {
    // This one CREATES a record, so it is where a contact with my own device
    // would be born — refused, as the emitters refuse to post one.
    if (await _owner._isSiblingDevice(peer)) return false;
    final existing = await _owner._storage.getContact(peer);
    if (existing?.status == status) return false;
    // A DOORBELL NEVER OVERWRITES A DECISION. Both devices receive the raw
    // request themselves, so a mirrored pending status carries no information
    // a decided record lacks — and device logs written before the poster
    // stopped mirroring pendings still hold such events, with timestamps that
    // can outrank the accept. Applying one regressed an accepted contact to
    // pendingIncoming on the device that folded both.
    if ((status == ContactStatus.pendingIncoming ||
            status == ContactStatus.pendingOutgoing) &&
        (existing?.status == ContactStatus.accepted ||
            existing?.status == ContactStatus.blocked)) {
      return false;
    }
    await _owner._storage.upsertContact(
      (existing ?? Contact(nodeId: peer)).copyWith(status: status),
    );
    if (status == ContactStatus.accepted) {
      _owner._realtimeControl.markAccepted(peer);
    } else {
      _owner._realtimeControl.revoke(peer);
    }
    _owner._signal();
    return true;
  }

  /// Shared handling for a [WireKind.request] AND a [WireKind.reconnect] — both
  /// (re-)establish consent. [status] is the sender's CURRENT contact status.
  ///
  /// * accepted — they re-sent because they never saw our accept (a lost accept,
  ///   or THEY wiped + re-intro'd and we still hold them): re-send + re-stash the
  ///   accept so the handshake completes, instead of stranding either side.
  /// * unknown / pending — surface as a pendingIncoming intro (the greeting),
  ///   bounded by [kMaxPreConsentIntros]; the user accepting heals delivery.
  /// (blocked is dropped before dispatch — no "you're blocked" oracle. The sender
  /// emits reconnect unconditionally after a no-ack threshold, so this path can't
  /// tell whether the peer was merely offline or actually wiped — by design.)
  Future<void> handleRequestOrReconnect(
    InboundMessage m,
    WireEnvelope env,
    ContactStatus? status,
  ) async {
    // You can't send yourself a connection request. Drop a self-addressed
    // request/reconnect so it never creates a bogus pendingIncoming
    // self-contact (Saved Messages is a chat with yourself, always accepted).
    if (m.src.hex == await _owner._selfHex()) return;
    if (status == ContactStatus.accepted) {
      // They re-requested/re-intro'd because they never saw our accept — re-send
      // it DURABLY (see [sendDurable]): the accept is a control frame that must
      // land, and this retry proves the first copy didn't. Force a fresh
      // mailbox deposit too — the previous one may have aged out at the relay.
      _owner._mailboxDelivery.removeStashed('accept:${m.src.hex}');
      await _owner.sendDurable(
        m.src,
        'accept:${m.src.hex}',
        const WireEnvelope.accept(),
      );
      return;
    }
    // Re-drives of a durable request/reconnect land here on every backoff tick
    // while the intro sits undecided (the durable gate only dedups ACCEPTED
    // senders) — only the FIRST arrival should write the contact record; the
    // rewrite is pure storage churn on every later copy.
    if (status != ContactStatus.pendingIncoming) {
      await setStatus(m.src, ContactStatus.pendingIncoming);
    }
    if (env.body.isNotEmpty &&
        !(env.id != null &&
            await _owner._storage.isMessageDeleted(m.src.hex, env.id!))) {
      // Bound pre-consent intros: a hostile peer minting a fresh id per
      // request/reconnect would otherwise pile up unbounded greetings before we
      // ever accept. Evict the oldest down to the cap, keeping the most recent.
      await capPreConsentIntros(m.src, env.id);
      // Store the greeting under its id so a later outbox re-send of the same
      // greeting (as a WireKind.message) dedups instead of creating a second copy.
      await _owner._store(
        m.src,
        MessageDirection.incoming,
        env.body,
        MessageStatus.delivered,
        id: env.id,
        timestamp: _owner._wireSentAt(env),
      );
    }
  }

  /// Ask [dst] to connect, with an optional [greeting]. We can't freely
  /// message them until they accept.
  ///
  /// Returns whether the request was DEPOSITED at the recipient's relay.
  ///
  /// It used to return nothing, and both legs below had their outcome thrown
  /// away — so a request that reached neither the relay nor the peer still
  /// left the contact marked `pendingOutgoing`, which the app shows as "sent".
  /// Measured on the production network: the seal could not be made because
  /// the recipient's instance registry did not resolve, nothing was deposited,
  /// and nothing anywhere said so. This send is also the one with no retry
  /// behind it — `flushOutbox` re-stashes ACCEPTED contacts only — so a
  /// silence here is permanent until somebody asks again by hand.
  Future<bool> sendRequest(NodeId dst, String greeting) async {
    final text = greeting.trim();
    await setStatus(dst, ContactStatus.pendingOutgoing);
    // Tag the greeting with a stable id shared between our stored copy and the
    // request on the wire. The greeting is stored `sent`, so the outbox re-sends
    // it as a WireKind.message after the peer accepts; without a shared id the
    // recipient (who stored the request body) couldn't dedup it and would show
    // the greeting twice.
    final id = _uuid.v4();
    final sentAt = DateTime.now();
    if (text.isNotEmpty) {
      await _owner._store(
        dst,
        MessageDirection.outgoing,
        text,
        MessageStatus.sent,
        id: id,
        timestamp: sentAt,
      );
    }
    _owner._signal();
    final wire = WireEnvelope.request(
      text,
      id: id,
      sentAtMs: sentAt.millisecondsSinceEpoch,
    ).encode();
    // Expect the accept/decline back as mailbox mail.
    _owner._mailboxDelivery.noteActivity();
    // Deposit the request at the recipient's mailbox relay so a NAT'd /
    // offline peer receives it. The live send below only lands if they're
    // directly reachable — which for two nodes behind NAT they never are, so
    // WITHOUT this first contact could never be established.
    //
    // STARTED BEFORE THE LIVE LEG, not after it, and this is the one send in
    // the app with no second chance: `flushOutbox` re-stashes ACCEPTED
    // contacts only, so nothing ever retries a request's deposit. Behind an
    // unbounded live send that made a stale direct address — a peer that
    // changed networks, whose endpoint the node will keep dialling — the one
    // condition under which first contact silently could not be made.
    final deposit = _owner._maybeStash(dst, id, wire);
    await _owner._outbox.boundedLiveLeg(_owner._send(dst, wire));
    final deposited = await deposit;
    // A greeting nothing carried is not "sent".
    //
    // Returning the verdict was half the answer: the caller could act on it,
    // but the conversation itself went on showing a message with a sent tick
    // beside it, and that is what a person looks at a minute later. Marking
    // it failed puts the error mark and the "Send again" button that already
    // exist on the one message they apply to (report19 XV19-M1).
    if (!deposited && text.isNotEmpty) {
      await _owner._storage.markMessageStatus(
        dst.hex,
        id,
        MessageStatus.failed,
      );
      _owner._signal();
    }
    return deposited;
  }

  /// Re-send a pending outgoing request that hasn't been accepted yet (e.g. it
  /// didn't reach the peer because a relay was momentarily unresolvable). Re-uses
  /// the original greeting + id (so the peer dedups), re-sends live AND forces a
  /// fresh mailbox deposit. No-op unless the contact is still pendingOutgoing.
  ///
  /// Returns whether the request was DEPOSITED, like [sendRequest] — this is
  /// what a person reaches for when the first attempt did not get through, so
  /// answering "sent" regardless was the least useful thing it could say
  /// (report19 XV19-M1). `false` also for the no-op: nothing was deposited.
  Future<bool> resendRequest(NodeId dst) async {
    final contact = await _owner._storage.getContact(dst);
    if (contact?.status != ContactStatus.pendingOutgoing) return false;
    String? body;
    String? id;
    for (final m in await _owner._storage.loadMessages(dst.hex)) {
      if (m.direction == MessageDirection.outgoing) {
        body = m.body;
        id = m.id;
        break;
      }
    }
    id ??= _uuid.v4();
    final wire = WireEnvelope.request(body ?? '', id: id).encode();
    // Same order as [sendRequest], and for a sharper reason: this method is
    // what a person reaches for when the request did not get through, so the
    // peer it addresses is the one already known not to be answering.
    _owner._mailboxDelivery.removeStashed(id); // allow a fresh deposit
    final deposit = _owner._maybeStash(dst, id, wire);
    await _owner._outbox.boundedLiveLeg(_owner._send(dst, wire));
    final deposited = await deposit;
    // The stored greeting follows the outcome in both directions: a retry
    // that lands clears the error mark the failed attempt left.
    if (body != null && body.isNotEmpty) {
      await _owner._storage.markMessageStatus(
        dst.hex,
        id,
        deposited ? MessageStatus.sent : MessageStatus.failed,
      );
    }
    _owner._signal();
    return deposited;
  }

  /// Cancel (retract) a pending outgoing request: remove the conversation +
  /// contact locally so the peer is unknown again and a fresh request can be
  /// sent later. The peer can't be un-notified (if it already arrived they may
  /// have seen it), but our side is cleaned up.
  Future<void> cancelRequest(NodeId peer) async {
    await _owner._storage.removeConversation(peer);
    // A retracted request makes the peer unknown again, so any session the
    // request itself opened has to go too — otherwise a "fresh" relationship
    // later resumes a chain from before it was withdrawn.
    await _owner._forgetRatchetWith(peer, 'request cancelled');
    _owner._signal();
  }

  /// Approve an incoming request — both sides can now message freely.
  Future<void> acceptContact(NodeId peer) async {
    await setStatus(peer, ContactStatus.accepted);
    _owner._signal();
    // DURABLE (see [sendDurable]): the requester is likely NAT'd/offline, and
    // an accept that dies on the lossy first live attempt (or our restart)
    // strands the whole relationship — they never learn they were accepted.
    // The pipeline live-sends, deposits at their mailbox, and re-drives until
    // their ack retires it. Stable id keys relay dedup per peer.
    await _owner.sendDurable(
      peer,
      'accept:${peer.hex}',
      const WireEnvelope.accept(),
    );
  }

  /// Decline / block an incoming request — their messages are dropped.
  Future<void> blockContact(NodeId peer) async {
    await setStatus(peer, ContactStatus.blocked);
    _owner._signal();
  }

  /// Messages kept aside per blocked contact, at most.
  static const kHeldWhileBlockedMax = 200;

  final Map<String, Set<String>> _heldIdsByPeer = {};
  final Set<String> _releasingHeldIds = {};

  String _heldIdKey(NodeId peer, String id) => '${peer.hex}\u001f$id';

  bool isReleasingHeld(NodeId peer, String id) =>
      _releasingHeldIds.contains(_heldIdKey(peer, id));

  Future<bool> isHeld(NodeId peer, String id) async {
    final cached = _heldIdsByPeer[peer.hex];
    if (cached != null) return cached.contains(id);
    final held = await _loadHeld(peer);
    final ids = _heldIdsByPeer[peer.hex] = {for (final h in held) h.id};
    return ids.contains(id);
  }

  String _heldKey(NodeId peer) => 'held-while-blocked:${peer.hex}';

  Uint8List _encodeHeld(List<_HeldBlockedMessage> held) => Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        for (final h in held)
          {
            'i': h.id,
            'w': h.wire,
            if (h.receivedAtMs != null) 't': h.receivedAtMs,
          },
      ]),
    ),
  );

  Future<List<_HeldBlockedMessage>> _loadHeld(NodeId peer) async {
    try {
      final raw = await _owner._storage.loadFile(_heldKey(peer));
      if (raw == null) return [];
      final list = jsonDecode(utf8.decode(raw));
      if (list is! List) return [];
      return [
        for (final e in list)
          if (e is Map && e['i'] is String && e['w'] is String)
            (
              id: e['i'] as String,
              wire: e['w'] as String,
              receivedAtMs: e['t'] is int ? e['t'] as int : null,
            ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveHeld(
    NodeId peer,
    List<_HeldBlockedMessage> held, {
    Uint8List? encoded,
  }) async {
    if (held.isEmpty) {
      await _owner._storage.deleteStoredFile(_heldKey(peer));
      _heldIdsByPeer[peer.hex] = {};
      return;
    }
    await _owner._storage.storeFile(
      _heldKey(peer),
      encoded ?? _encodeHeld(held),
      name: 'held-while-blocked',
    );
    _heldIdsByPeer[peer.hex] = {for (final h in held) h.id};
  }

  /// Keep [wire] (a message envelope from blocked [peer]) aside. False when
  /// the payload store is full: the caller still records a body-less marker
  /// and ACKs it, so an overflow cannot arrive unasked after unblock.
  Future<bool> holdWhileBlocked(NodeId peer, String id, Uint8List wire) async {
    final held = await _loadHeld(peer);
    if (held.any((h) => h.id == id)) return true;
    if (held.length >= kHeldWhileBlockedMax) return false;
    held.add((
      id: id,
      wire: base64Encode(wire),
      receivedAtMs: _owner._now().millisecondsSinceEpoch,
    ));
    final encoded = _encodeHeld(held);
    // The whole queue is one encrypted file. Its byte limit can arrive
    // before the 200-message count limit; treat that as the same overflow so
    // the caller still records a void and ACKs the message while blocked.
    if (encoded.length > kMaxStoredFileBytes) return false;
    await _saveHeld(peer, held, encoded: encoded);
    _owner._signal();
    return true;
  }

  /// How many messages from [peer] arrived while it was blocked here.
  Future<int> heldWhileBlocked(NodeId peer) async =>
      (await _loadHeld(peer)).length;

  /// Show them: each goes through the ordinary receive path, as if it had
  /// just arrived — now that the contact is no longer blocked.
  Future<int> releaseHeld(NodeId peer) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact?.status == ContactStatus.blocked) return 0;
    final held = await _loadHeld(peer);
    final remaining = <_HeldBlockedMessage>[];
    var released = 0;
    for (final h in held) {
      final key = _heldIdKey(peer, h.id);
      _releasingHeldIds.add(key);
      try {
        await _owner.deliverInbound(
          InboundMessage(
            src: peer,
            payload: base64Decode(h.wire),
            provenance: SenderProvenance.signed,
          ),
        );
        // The dispatch catches malformed frames and failed writes. Keep the
        // held copy unless it actually reached the conversation; a restart
        // then offers Show again instead of silently losing the message.
        if (await _owner._storage.loadMessageById(peer.hex, h.id) != null) {
          released++;
        } else if (!await _owner._storage.isMessageDeleted(peer.hex, h.id)) {
          remaining.add(h);
        }
      } catch (e) {
        remaining.add(h);
        devLog(() => 'xVeil[recv]: releasing held message failed: $e');
      } finally {
        _releasingHeldIds.remove(key);
      }
    }
    await _saveHeld(peer, remaining);
    _owner._signal();
    return released;
  }

  /// Forget them, unread.
  Future<void> discardHeld(NodeId peer) async {
    await _saveHeld(peer, const []);
    _owner._signal();
  }

  /// A sibling's clear may arrive after newer blocked messages. Keep those
  /// received after the clear; old queue rows had no receipt time and cannot
  /// be shown safely once that history has been cleared.
  Future<void> discardHeldThrough(NodeId peer, int atMs) async {
    // Match applyRemoteClear's cap on a sibling clock running ahead of ours.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final throughMs = atMs < nowMs ? atMs : nowMs;
    final held = await _loadHeld(peer);
    final remaining = [
      for (final h in held)
        if (_heldAfterClear(h, throughMs)) h,
    ];
    if (remaining.length == held.length) return;
    await _saveHeld(peer, remaining);
    _owner._signal();
  }

  bool _heldAfterClear(_HeldBlockedMessage held, int throughMs) {
    final receivedAt = held.receivedAtMs;
    if (receivedAt == null || receivedAt <= throughMs) return false;
    try {
      final sentAt = WireEnvelope.decode(base64Decode(held.wire)).sentAtMs;
      return sentAt == null ||
          messageTsOnReceipt(sentAt, receivedAt) > throughMs;
    } catch (_) {
      return false;
    }
  }

  /// Lift a block — the peer becomes an accepted contact again so their
  /// messages are delivered (and we can message them). Local-only: the peer is
  /// never told they were blocked or unblocked (no presence/relationship
  /// oracle). Retries of messages received during the block remain hidden.
  Future<void> unblockContact(NodeId peer) async {
    await setStatus(peer, ContactStatus.accepted);
    _owner._signal();
  }
}
