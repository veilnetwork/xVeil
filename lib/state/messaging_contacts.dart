part of 'messaging_core.dart';

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
    final existing = await _owner._storage.getContact(peer);
    if (existing?.status == status) return false;
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
  Future<void> sendRequest(NodeId dst, String greeting) async {
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
    await _owner._send(dst, wire);
    // Also deposit the request at the recipient's mailbox relay so a NAT'd /
    // offline peer receives it. The live send above only lands if they're
    // directly reachable — which for two nodes behind NAT they never are, so
    // WITHOUT this first contact could never be established. (flushOutbox only
    // re-stashes ACCEPTED contacts, so the request must stash itself here.)
    await _owner._maybeStash(dst, id, wire);
  }

  /// Re-send a pending outgoing request that hasn't been accepted yet (e.g. it
  /// didn't reach the peer because a relay was momentarily unresolvable). Re-uses
  /// the original greeting + id (so the peer dedups), re-sends live AND forces a
  /// fresh mailbox deposit. No-op unless the contact is still pendingOutgoing.
  Future<void> resendRequest(NodeId dst) async {
    final contact = await _owner._storage.getContact(dst);
    if (contact?.status != ContactStatus.pendingOutgoing) return;
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
    await _owner._send(dst, wire);
    _owner._mailboxDelivery.removeStashed(id); // allow a fresh deposit
    await _owner._maybeStash(dst, id, wire);
    _owner._signal();
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

  /// Lift a block — the peer becomes an accepted contact again so their
  /// messages are delivered (and we can message them). Local-only: the peer is
  /// never told they were blocked or unblocked (no presence/relationship
  /// oracle). A still-buffered re-send from them will flow on its next arrival.
  Future<void> unblockContact(NodeId peer) async {
    await setStatus(peer, ContactStatus.accepted);
    _owner._signal();
  }
}
