part of 'messaging_core.dart';

typedef _HeldBlockedMessage = ({String id, String wire, int? receivedAtMs});

/// Local submission and relay admission are different from peer delivery.
enum ContactRequestSubmission {
  refused,
  queued,
  deposited,
  messageSubmitted,
  alreadyAccepted;

  /// A queued request, ordinary message or allowed no-op was admitted locally.
  /// This is not proof that a recipient or mailbox relay received it.
  bool get admitted => this != refused;
}

/// Contact consent and relationship lifecycle.
///
/// Owns request/reconnect handling, pre-consent anti-spam bounds, local and
/// mirrored status transitions, and the user-facing relationship actions.
class _MessagingContacts {
  _MessagingContacts(this._owner);

  final MessagingService _owner;
  final _acceptances = <Future<void>>{};
  // Only active response jobs own a token (bounded by the recipient queue's
  // concurrency). Retiring a row invalidates metadata still being read; an
  // already-started transport future continues to hold its lane until done.
  final _acceptanceAdmissions = <String, Object>{};

  void retireAcceptance(String peerHex, String frameId) {
    final prefix = 'accept:$peerHex';
    if (frameId != prefix && !frameId.startsWith('$prefix:')) return;
    _acceptanceAdmissions.remove(frameId);
    _owner._contactResponseQueue.cancelPending(frameId);
  }

  Future<void> close() async {
    while (_acceptances.isNotEmpty) {
      await Future.wait(_acceptances.toList());
    }
  }

  /// Bound the number of pre-consent intro messages held from a single
  /// not-yet-accepted [peer] (anti-spam). Each [WireKind.request] greeting is
  /// stored so the consent prompt can show it; before acceptance the only
  /// incoming messages from a peer ARE these intros (real messages are gated on
  /// `accepted`), so capping incoming-count == capping intros. We evict the
  /// oldest so that, after storing the new intro [newId], we retain at most
  /// [kMaxPreConsentIntros]. No-op for an accepted peer (we must never evict a
  /// real conversation) or a same-id re-send (it overwrites in place, not a new
  /// intro). Evicted bodies are scrubbed so they leave no recoverable trace.
  /// False leaves the current owner's decided/retired conversation untouched.
  Future<bool> capPreConsentIntros(
    NodeId peer,
    String? newId,
    bool Function() isCurrent,
  ) async {
    final contact = await _owner._storage.getContact(peer);
    if (!isCurrent() ||
        (contact?.status != ContactStatus.pendingIncoming &&
            contact?.status != ContactStatus.pendingOutgoing)) {
      return false;
    }
    final msgs = await _owner._storage.loadMessages(peer.hex);
    if (newId != null && msgs.any((m) => m.id == newId)) return isCurrent();
    final intros =
        msgs.where((m) => m.direction == MessageDirection.incoming).toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Make room for the one we're about to add: keep at most cap-1 of the old.
    final evict = intros.length - (kMaxPreConsentIntros - 1);
    if (evict <= 0) return isCurrent();
    return _owner._storage.trimPendingContactIntroductions(
      peer,
      intros.take(evict).map((m) => m.id).toList(),
      isCurrent: isCurrent,
    );
  }

  Future<void> setStatus(NodeId peer, ContactStatus status) async {
    await _withConsentWrite(
      peer,
      () => _owner._storage.setContactStatus(peer, status),
    );
    await _afterStatusSaved(peer, status);
  }

  Future<bool> acceptOutgoingRequest(NodeId peer) async {
    final accepted = await _withConsentWrite(
      peer,
      () => _owner._storage.acceptOutgoingContactRequest(peer),
    );
    if (!accepted) return false;
    await _afterStatusSaved(peer, ContactStatus.accepted);
    return true;
  }

  Future<T> _withConsentWrite<T>(
    NodeId peer,
    Future<T> Function() write,
  ) async {
    if (_owner._disposed) throw StateError('messaging service is closed');
    // Also invalidate on completion/failure: a read begun DURING a blocked
    // write may have observed the previous accepted record.
    _owner._realtimeControl.revoke(peer);
    try {
      return await write();
    } finally {
      _owner._realtimeControl.revoke(peer);
    }
  }

  Future<void> _afterStatusSaved(
    NodeId peer,
    ContactStatus status, {
    bool local = true,
  }) async {
    // Cleanup and publication belong to the current durable relationship.
    // Listing the queue can finish after deletion and a replacement request.
    final consent = _owner._realtimeControl;
    final current = await consent._readContactConsent(peer);
    bool isCurrent() => consent._consentCurrent(peer, current?.epoch);
    if (current?.contact?.status != status || !isCurrent()) return;
    if (status == ContactStatus.accepted) {
      await _owner._outbox.retireRequests(peer, isCurrent: isCurrent);
      if (!isCurrent()) return;
    }
    _owner._contactStatusChanges.add((peer: peer, status: status));
    if (local) _owner.onContactStatusChanged?.call(peer, status);
  }

  /// Apply a relationship status mirrored from ANOTHER of my devices. Unlike
  /// the preference mirror this CREATES a missing contact (that is the
  /// contact-list sync: an add/accept/block decided on my other device is the
  /// same owner's decision), preserving every other field of an existing
  /// record. Writes straight to storage — never re-fires
  /// [_owner.onContactStatusChanged], so a mirrored status cannot echo.
  Future<bool> applyMirroredContactStatus(
    NodeId peer,
    ContactStatus status, {
    int? atMs,
  }) async {
    if (_owner._disposed) return false;
    // This one CREATES a record, so it is where a contact with my own device
    // would be born — refused, as the emitters refuse to post one.
    if (await _owner._isSiblingDevice(peer)) return false;
    if (_owner._disposed) return false;
    final existing = await _owner._storage.getContact(peer);
    if (_owner._disposed) return false;
    if (atMs == null && existing?.status == status) return false;
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
    if (status == ContactStatus.pendingIncoming ||
        status == ContactStatus.pendingOutgoing) {
      // The snapshot check above is only a fast path. A local decision can
      // commit while it is being read; use the same guarded contact write as
      // live requests so a delayed device-journal doorbell cannot undo it or
      // replace newer preferences with the earlier snapshot.
      final effective = await _owner._storage.prepareContactRequest(
        peer,
        incoming: status == ContactStatus.pendingIncoming,
      );
      if (effective != status) return false;
    } else if (atMs != null &&
        (status == ContactStatus.accepted || status == ContactStatus.blocked)) {
      if (!await _withConsentWrite(
        peer,
        () => _owner._storage.applyContactDecision(peer, status, atMs),
      )) {
        return false;
      }
    } else {
      await _withConsentWrite(
        peer,
        () => _owner._storage.upsertContact(
          (existing ?? Contact(nodeId: peer)).copyWith(status: status),
        ),
      );
    }
    await _afterStatusSaved(peer, status, local: false);
    if (_owner._disposed) return false;
    _owner._signal();
    return true;
  }

  /// Shared handling for a [WireKind.request] AND a [WireKind.reconnect] — both
  /// (re-)establish consent. [initialStatus] is only the ingress snapshot;
  /// asynchronous checks must not turn it into a new relationship decision.
  ///
  /// * accepted — they re-sent because they never saw our accept (a lost accept,
  ///   or THEY wiped + re-intro'd and we still hold them): re-send + re-stash the
  ///   accept so the handshake completes, instead of stranding either side.
  /// * unknown / pending — surface as a pendingIncoming intro (the greeting),
  ///   bounded by [kMaxPreConsentIntros]; the user accepting heals delivery.
  /// (blocked is dropped before dispatch — no "you're blocked" oracle. The sender
  /// emits reconnect unconditionally after a no-ack threshold, so this path can't
  /// tell whether the peer was merely offline or actually wiped — by design.)
  /// False leaves an unprocessed carrier copy unacknowledged.
  Future<bool> handleRequestOrReconnect(
    InboundMessage m,
    WireEnvelope env,
    ContactStatus? initialStatus,
  ) async {
    // You can't send yourself a connection request. Drop a self-addressed
    // request/reconnect so it never creates a bogus pendingIncoming
    // self-contact (Saved Messages is a chat with yourself, always accepted).
    if (m.src.hex == await _owner._selfHex()) return false;
    if (_owner._disposed) {
      _owner._declinedLocally(m, 'messaging service is closed');
      return false;
    }
    final epoch = _owner._realtimeControl._consentEpoch(m.src);
    bool isCurrent() => _owner._realtimeControl._consentCurrent(m.src, epoch);
    // Preparing a pending intro cannot revoke or grant accepted access. It
    // preserves decided relationships under the storage contact lane. Do not
    // invalidate an in-progress outgoing greeting merely for a crossed intro.
    final status = await _owner._storage.prepareContactRequest(
      m.src,
      incoming: true,
    );
    if (_owner._disposed) {
      _owner._declinedLocally(m, 'messaging service is closed');
      return false;
    }
    if (status == ContactStatus.blocked) {
      _owner._declinedLocally(m, 'contact changed during request admission');
      return false;
    }
    if (status == ContactStatus.accepted) {
      // They re-requested/re-intro'd because they never saw our accept — re-send
      // it DURABLY (see [sendDurable]): the accept is a control frame that must
      // land, and this retry proves the first copy didn't. Force a fresh
      // mailbox deposit too — the previous one may have aged out at the relay.
      return _queueAcceptance(m.src);
    }
    // Re-drives of a durable request/reconnect land here on every backoff tick
    // while the intro sits undecided (the durable gate only dedups ACCEPTED
    // senders) — only the FIRST arrival should write the contact record; the
    // rewrite is pure storage churn on every later copy.
    if (initialStatus != ContactStatus.pendingIncoming) {
      final consent = await _owner._realtimeControl._readContactConsent(m.src);
      final currentStatus = consent?.contact?.status;
      if (!isCurrent() ||
          (currentStatus != ContactStatus.pendingIncoming &&
              currentStatus != ContactStatus.pendingOutgoing)) {
        return _finishSupersededIntroduction(m);
      }
      // A decision may have completed while prepare/read waited. Never emit
      // its old pending status into the UI or the own-device journal.
      await _afterStatusSaved(m.src, currentStatus!);
    }
    if (env.body.isNotEmpty &&
        !(env.id != null &&
            await _owner._storage.isMessageDeleted(m.src.hex, env.id!))) {
      // Bound pre-consent intros: a hostile peer minting a fresh id per
      // request/reconnect would otherwise pile up unbounded greetings before we
      // ever accept. Evict the oldest down to the cap, keeping the most recent.
      if (!await capPreConsentIntros(m.src, env.id, isCurrent)) {
        return _finishSupersededIntroduction(m);
      }
      // Store the greeting under its id so a later outbox re-send of the same
      // greeting (as a WireKind.message) dedups instead of creating a second copy.
      // An undecided request may arrive many times. New requests carry their
      // original sender sequence; a legacy retry must keep the first local
      // position rather than allocating a fresh sequence on every arrival.
      final held = env.id == null
          ? null
          : await _owner._storage.loadMessageById(m.src.hex, env.id!);
      final intro =
          held?.direction == MessageDirection.incoming &&
              held?.author == m.src.hex
          ? held
          : null;
      final stored = await _owner._store(
        m.src,
        MessageDirection.incoming,
        env.body,
        MessageStatus.delivered,
        id: env.id,
        timestamp: _owner._wireSentAt(env) ?? intro?.timestamp,
        seq: env.seq ?? intro?.seq,
        pendingIntroduction: isCurrent,
      );
      if (stored == null) {
        return _finishSupersededIntroduction(m, expiredPending: isCurrent);
      }
    }
    return true;
  }

  Future<bool> _finishSupersededIntroduction(
    InboundMessage message, {
    bool Function()? expiredPending,
  }) async {
    final consent = await _owner._realtimeControl._readContactConsent(
      message.src,
    );
    if (consent?.contact?.status == ContactStatus.accepted) {
      // Acceptance may have won while discovery waited. Preserve the normal
      // accepted re-request response, without importing its unverified body.
      return _queueAcceptance(message.src);
    }
    // The shared store can also suppress a deleted/expired intro without a
    // consent change. Preserve that handled outcome while it is still owned.
    if (expiredPending?.call() == true &&
        (consent?.contact?.status == ContactStatus.pendingIncoming ||
            consent?.contact?.status == ContactStatus.pendingOutgoing)) {
      return true;
    }
    _owner._declinedLocally(message, 'contact changed during intro admission');
    return false;
  }

  /// Finish durable admission inside ingress; send on bounded recipient lanes.
  /// A retrying accepted contact must not hold the ordinary inbox behind a
  /// slow reverse route. Failed/dropped jobs keep their durable Outbox copy.
  Future<bool> _queueAcceptance(NodeId peer) async {
    final frameId = 'accept:${peer.hex}:${_uuid.v4()}';
    final wire = const WireEnvelope.accept().withFrameId(frameId).encode();
    final frame = await _owner._outbox.enqueueAcceptance(
      peer,
      frameId,
      wire,
      replyOnly: true,
    );
    if (frame == null || _owner._disposed) return false;
    _owner._mailboxDelivery.removeStashed(peer.hex, frame.frameId);
    unawaited(_sendStoredAcceptance(peer, frame));
    return true;
  }

  Future<void> _sendStoredAcceptance(NodeId peer, OutboxFrame frame) {
    if (_owner._disposed) return Future.value();
    final frameId = frame.frameId, wire = frame.wire;
    return _owner._contactResponseQueue.submit(
      key: frameId,
      lane: peer.hex,
      bytes: 512 + 2 * wire.length + 6 * frameId.length,
      send: () async {
        if (_owner._disposed) return;
        final admission = Object();
        _acceptanceAdmissions[frameId] = admission;
        bool current() =>
            !_owner._disposed &&
            identical(_acceptanceAdmissions[frameId], admission);
        try {
          final skipLive = await _owner._outbox._longSilent(peer.hex);
          final consent = await _owner._realtimeControl._readContactConsent(
            peer,
          );
          if (consent?.contact?.status != ContactStatus.accepted) return;
          bool consentCurrent() =>
              _owner._realtimeControl._consentCurrent(peer, consent?.epoch);
          // No enqueue here. An ACK during either read invalidates admission,
          // even when a delayed storage reply still reports membership=true.
          if (!await _owner._storage.containsOutboxFrame(frame) ||
              !current() ||
              !consentCurrent()) {
            return;
          }
          _owner._stashInBackground(
            peer,
            frameId,
            wire,
            isCurrent: consentCurrent,
          );
          if (skipLive) return;
          _owner._outbox.recordQueued(frameId, peer.hex);
          await _owner._send(peer, wire);
        } finally {
          if (identical(_acceptanceAdmissions[frameId], admission)) {
            _acceptanceAdmissions.remove(frameId);
          }
        }
      },
    );
  }

  /// Ask [dst] to connect, with an optional [greeting]. We can't freely
  /// message them until they accept.
  ///
  /// Distinguishes durable local admission from a successful relay deposit.
  /// An accepted contact receives an ordinary message (or an empty no-op).
  /// A blocked contact is left blocked and refused. None proves peer delivery.
  ///
  /// It used to return nothing, and both legs below had their outcome thrown
  /// away — so a request that reached neither the relay nor the peer still
  /// left the contact marked `pendingOutgoing`, which the app showed as "sent".
  /// Measured on the production network: the seal could not be made because
  /// the recipient's instance registry did not resolve, nothing was deposited,
  /// and nothing anywhere said so. Persist the handshake before either leg
  /// so an unsuccessful first attempt can retry after reconnect or restart.
  Future<ContactRequestSubmission> submitRequest(
    NodeId dst,
    String greeting,
  ) async {
    final text = greeting.trim();
    if (_owner._disposed) throw StateError('messaging service is closed');
    // Keep the originating relationship lifetime across preparation, greeting
    // persistence and queue admission. Pending preparation itself never changes
    // decided consent, so concurrent new/crossed greetings share this lifetime;
    // block, accept, cancel and owner shutdown still revoke it.
    final epoch = _owner._realtimeControl._consentEpoch(dst);
    bool isCurrent() => _owner._realtimeControl._consentCurrent(dst, epoch);
    final status = await _owner._storage.prepareContactRequest(dst);
    if (_owner._disposed || status == ContactStatus.blocked) {
      return ContactRequestSubmission.refused;
    }
    if (status == ContactStatus.accepted) {
      // The composer may still hold its pre-accept snapshot. A new request
      // must not demote an established conversation or discard this text as
      // an ignored re-introduction at the other end.
      if (text.isEmpty) return ContactRequestSubmission.alreadyAccepted;
      return await _owner.sendText(dst, text)
          ? ContactRequestSubmission.messageSubmitted
          : ContactRequestSubmission.refused;
    }
    if (!isCurrent()) return ContactRequestSubmission.refused;
    await _afterStatusSaved(dst, status);
    // Tag the greeting with a stable id shared between our stored copy and the
    // request on the wire. The greeting is stored `sent`, so the outbox re-sends
    // it as a WireKind.message after the peer accepts; without a shared id the
    // recipient (who stored the request body) couldn't dedup it and would show
    // the greeting twice.
    final id = _uuid.v4();
    final sentAt = DateTime.now();
    int? seq;
    if (text.isNotEmpty) {
      final stored = await _owner._store(
        dst,
        MessageDirection.outgoing,
        text,
        MessageStatus.sending,
        id: id,
        timestamp: sentAt,
      );
      // Erasure/expiry is not permission to emit an empty replacement request.
      if (stored == null) return ContactRequestSubmission.refused;
      seq = stored.seq;
    }
    _owner._signal();
    final frameId = 'request:$id';
    final wire = WireEnvelope.request(
      text,
      id: id,
      sentAtMs: sentAt.millisecondsSinceEpoch,
      seq: seq,
    ).withFrameId(frameId).encode();
    // Survive a failed deposit, a lost live leg and an application restart.
    // The peer's acceptance or cancellation retires this handshake row.
    if (!isCurrent() ||
        !await _owner._outbox.admitInitialRequest(
          dst,
          frameId,
          wire,
          isCurrent: isCurrent,
        )) {
      return ContactRequestSubmission.refused;
    }
    // Admission may complete just before a newer decision. Its queued result
    // remains truthful, but no new network attempt belongs to the old lifetime.
    if (!isCurrent()) return ContactRequestSubmission.queued;
    // Expect the accept/decline back as mailbox mail.
    _owner._mailboxDelivery.noteActivity();
    // Deposit the request at the recipient's mailbox relay so a NAT'd /
    // offline peer can receive it later. The live leg uses available routes;
    // neither its completion nor a failed deposit proves remote delivery.
    //
    // Deposit starts before the bounded live leg. If neither reaches the
    // recipient, the persisted request is re-driven by the ordinary outbox.
    final deposit = _owner._maybeStash(
      dst,
      frameId,
      wire,
      isCurrent: isCurrent,
    );
    await _owner._outbox.boundedLiveLeg(_owner._send(dst, wire));
    final deposited = await deposit;
    // A failed mailbox deposit does not prove the live leg failed. On a phone
    // the direct leg can arrive minutes later as routes warm up. Keep the
    // greeting pending until a relay accepts it or the peer accepts us; a
    // failed mark incorrectly claimed the request could no longer arrive.
    if (text.isNotEmpty && isCurrent()) {
      final accepted =
          (await _owner._storage.getContact(dst))?.status ==
          ContactStatus.accepted;
      if (!isCurrent()) {
        return deposited
            ? ContactRequestSubmission.deposited
            : ContactRequestSubmission.queued;
      }
      await _owner._storage.markMessageStatus(
        dst.hex,
        id,
        accepted
            ? MessageStatus.delivered
            : deposited
            ? MessageStatus.sent
            : MessageStatus.sending,
      );
      _owner._signal();
    }
    return deposited
        ? ContactRequestSubmission.deposited
        : ContactRequestSubmission.queued;
  }

  /// Re-send a pending outgoing request that hasn't been accepted yet (e.g. it
  /// didn't reach the peer because a relay was momentarily unresolvable). Re-uses
  /// the original greeting + id (so the peer dedups), re-sends live AND forces a
  /// fresh mailbox deposit. No-op unless the contact is still pendingOutgoing.
  ///
  /// Returns whether the request was DEPOSITED, like
  /// [MessagingService.sendRequest] — this is
  /// what a person reaches for when the first attempt did not get through, so
  /// answering "sent" regardless was the least useful thing it could say
  /// (report19 XV19-M1). `false` also for the no-op: nothing was deposited.
  Future<bool> resendRequest(NodeId dst) async {
    final consent = await _owner._realtimeControl._readContactConsent(dst);
    if (consent?.contact?.status != ContactStatus.pendingOutgoing) return false;
    bool isCurrent() =>
        _owner._realtimeControl._consentCurrent(dst, consent!.epoch);
    String? body;
    String? id;
    int? sentAtMs;
    int? seq;
    OutboxFrame? original;
    for (final frame in await _owner._storage.pendingOutboxFrames()) {
      if (frame.peerHex != dst.hex || !frame.frameId.startsWith('request:')) {
        continue;
      }
      try {
        final request = WireEnvelope.decode(frame.wire);
        if (request.kind != WireKind.request) continue;
        id = request.id;
        body = request.body;
        sentAtMs = request.sentAtMs;
        seq = request.seq;
        if (id != null) original = frame;
        break;
      } catch (_) {
        /* Try the legacy greeting record below. */
      }
    }
    if (id == null) {
      for (final m in await _owner._storage.loadMessages(dst.hex)) {
        if (m.direction == MessageDirection.outgoing) {
          body = m.body;
          id = m.id;
          sentAtMs = m.timestamp.millisecondsSinceEpoch;
          seq = m.seq;
          break;
        }
      }
    } else if (body?.isNotEmpty == true && (sentAtMs == null || seq == null)) {
      // Upgrade a pre-sequence durable request from its committed local row.
      // Never restamp a manual retry: it is still the same logical greeting.
      final stored = await _owner._storage.loadMessageById(dst.hex, id);
      if (stored?.direction == MessageDirection.outgoing) {
        sentAtMs ??= stored!.timestamp.millisecondsSinceEpoch;
        seq ??= stored!.seq;
      }
    }
    id ??= _uuid.v4();
    final frameId = 'request:$id';
    final wire = WireEnvelope.request(
      body ?? '',
      id: id,
      sentAtMs: sentAtMs,
      seq: seq,
    ).withFrameId(frameId).encode();
    if (!isCurrent() ||
        !await _owner._outbox.admitRequestRetry(
          dst,
          frameId,
          wire,
          expected: original,
          isCurrent: isCurrent,
        ) ||
        !isCurrent()) {
      return false;
    }
    // Same order as [sendRequest], and for a sharper reason: this method is
    // what a person reaches for when the request did not get through, so the
    // peer it addresses is the one already known not to be answering.
    _owner._mailboxDelivery.removeStashed(dst.hex, frameId);
    // The relay keeps the first blob stored under (recipient, contentId).
    // Reusing the original deposit id would report success while leaving a
    // ciphertext the recipient could not open in place. Keep the wire id for
    // message dedup, but give every manual retry a fresh mailbox content id.
    final depositId = '$id:retry:${_uuid.v4()}';
    final deposit = _owner._maybeStash(
      dst,
      depositId,
      wire,
      isCurrent: isCurrent,
    );
    await _owner._outbox.boundedLiveLeg(_owner._send(dst, wire));
    final deposited = await deposit;
    // The outbox tracks the logical frame, not this manual attempt key.
    // Drop the attempt bookkeeping and remember its successful deposit below.
    _owner._mailboxDelivery.removeStashed(dst.hex, depositId);
    if (!isCurrent()) return deposited;
    if (deposited) _owner._mailboxDelivery.rememberDeposited(frameId);
    // A direct copy may still arrive after a failed deposit. Keep the greeting
    // pending unless a relay accepted it or the peer has accepted the request.
    if (body != null && body.isNotEmpty) {
      final accepted =
          (await _owner._storage.getContact(dst))?.status ==
          ContactStatus.accepted;
      if (!isCurrent()) return deposited;
      await _owner._storage.markMessageStatus(
        dst.hex,
        id,
        accepted
            ? MessageStatus.delivered
            : deposited
            ? MessageStatus.sent
            : MessageStatus.sending,
      );
    }
    if (isCurrent()) _owner._signal();
    return deposited;
  }

  /// Cancel (retract) a pending outgoing request: remove the conversation +
  /// contact locally so the peer is unknown again and a fresh request can be
  /// sent later. The peer can't be un-notified (if it already arrived they may
  /// have seen it), but our side is cleaned up.
  Future<bool> cancelRequest(NodeId peer) async {
    if (_owner._disposed) throw StateError('messaging service is closed');
    final consent = _owner._realtimeControl;
    final requested = consent._consentEpoch(peer);
    // Avoid touching a stale action's queue. This read is only an early exit;
    // the storage operation rechecks under the contact write lane after all
    // asynchronous retirement work. Retire first so a failed forensic scrub
    // cannot leave a request retrying after its contact has been erased.
    if ((await _owner._storage.getContact(peer))?.hasOutgoingRequest != true ||
        !consent._consentCurrent(peer, requested)) {
      return false;
    }
    consent.revoke(peer);
    final cancelling = consent._consentEpoch(peer);
    bool isCurrent() => consent._consentCurrent(peer, cancelling);
    try {
      await _owner._outbox.retireRequests(peer, isCurrent: isCurrent);
      if (!isCurrent() ||
          !await _owner._storage.cancelPendingContactRequest(
            peer,
            isCurrent: isCurrent,
          )) {
        return false;
      }
    } finally {
      // A refused earlier action must not invalidate preparation of the
      // replacement. Reads started during our own write still need revocation.
      if (consent._consentRevisionCurrent(peer, cancelling)) {
        consent.revoke(peer);
      }
    }
    // A retracted request makes the peer unknown again, so any session the
    // request itself opened has to go too — otherwise a "fresh" relationship
    // later resumes a chain from before it was withdrawn.
    await _owner._forgetRatchetWith(peer, 'request cancelled');
    _owner._signal();
    return true;
  }

  /// Approve an incoming request — both sides can now message freely.
  Future<void> acceptContact(NodeId peer) {
    if (_owner._disposed) {
      return Future.error(StateError('messaging service is closed'));
    }
    final result = _acceptContact(peer);
    late final Future<void> settled;
    settled = result
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (error is ContactAcceptanceSuperseded) return;
            // Joining owned work also observes its error. Keep a safe diagnostic
            // even when a UI callback does not await the returned future.
            const message = 'Contact acceptance could not be completed';
            final Object safe = switch (error) {
              FileSystemException(:final osError) => FileSystemException(
                message,
                null,
                osError == null
                    ? null
                    : OSError('operation refused', osError.errorCode),
              ),
              FormatException() => const FormatException(message),
              _ => StateError(message),
            };
            errorJournal.record(
              kind: 'contact-accept',
              error: safe,
              stack: stack,
              atMs: DateTime.now().millisecondsSinceEpoch,
            );
          },
        )
        .whenComplete(() {
          _acceptances.remove(settled);
        });
    _acceptances.add(settled);
    return result;
  }

  Future<void> _acceptContact(NodeId peer) async {
    final frameId = 'accept:${peer.hex}:${_uuid.v4()}';
    final wire = const WireEnvelope.accept().withFrameId(frameId).encode();
    // User-visible consent and the response obligation share one transaction.
    // No callback/live send can advertise a decision with no durable answer.
    final frame = await _withConsentWrite(
      peer,
      () => _owner._outbox.enqueueAcceptance(peer, frameId, wire),
    );
    if (frame == null) return;
    try {
      if (_owner._disposed) return;
      await _afterStatusSaved(peer, ContactStatus.accepted);
    } finally {
      if (!_owner._disposed) {
        _owner._signal();
        // Never enqueue again here: an ACK/retry may already have retired
        // the committed frame. Keep the caller's bounded initial-send wait.
        await _owner._outbox.boundedLiveLeg(_sendStoredAcceptance(peer, frame));
      }
    }
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
