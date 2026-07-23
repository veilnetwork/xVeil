part of 'messaging_core.dart';

/// Serialized, fail-closed dispatch for authenticated durable wire frames.
///
/// Parsing remains behind the contact/consent and replay gates established by
/// [MessagingService]. Keeping every [WireKind] branch in one module makes the
/// inbound protocol surface auditable without mixing it with send APIs.
extension _MessagingInboundDispatch on MessagingService {
  Future<void> _dispatch(InboundMessage m) async {
    final env = WireEnvelope.decode(m.payload);
    final existing = await _storage.getContact(m.src);
    if (existing?.status == ContactStatus.blocked) return; // drop blocked
    if (existing?.status == ContactStatus.accepted) {
      _realtimeControl.markAccepted(m.src);
    }

    // Durable-frame ack + dedup (generic, any kind): a frame sent via
    // [sendDurable] carries a frameId. Ack it so the sender retires it from its
    // outbox, and process it only ONCE — a re-drive (the sender never got our
    // ack, or we restarted) is re-acked but not re-processed. Consent-gated:
    // only accepted peers reach the durable handlers below.
    final fid = env.frameId;
    final deferredPersistenceAck =
        env.kind == WireKind.cloudDocument ||
        env.kind == WireKind.cloudDocumentChunk ||
        env.kind == WireKind.spaceInvite ||
        env.kind == WireKind.spaceInviteDecision ||
        env.kind == WireKind.spaceJoinRequest ||
        env.kind == WireKind.spaceJoinDecision ||
        env.kind == WireKind.spaceModerationAppeal ||
        env.kind == WireKind.spaceModerationAppealDecision ||
        env.kind == WireKind.spaceAbuseReport ||
        env.kind == WireKind.spaceAbuseReportDecision;
    final deferredGroupCallAck = env.kind == WireKind.groupCallSignal;
    final liveOnlyNoAck =
        env.kind == WireKind.groupContentReceipt ||
        env.kind == WireKind.groupContentManifest ||
        env.kind == WireKind.spacePublicFeedRequest ||
        env.kind == WireKind.spacePublicFeedChunk ||
        env.kind == WireKind.spacePublicMediaGrantRequest;
    if (fid != null && deferredGroupCallAck && _outbox.hasSeen(fid)) {
      // This exact frame passed membership+AEAD+signature once already. A
      // re-drive means our prior ACK was lost; re-ACK without reprocessing.
      await _ackFrame(m, fid);
      return;
    }
    if (fid != null &&
        !liveOnlyNoAck &&
        existing?.status == ContactStatus.accepted) {
      if (deferredGroupCallAck) {
        // Authorization is the group frame itself, not ContactStatus. The
        // groupCallSignal switch arm ACKs only after the group layer accepts.
      } else if (deferredPersistenceAck) {
        if (_outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
      } else {
        await _ackFrame(m, fid);
        if (!_outbox.remember(fid)) {
          return; // already processed — re-acked above
        }
      }
    }

    switch (env.kind) {
      case WireKind.request:
        await _handleRequestOrReconnect(m, env, existing?.status);
      case WireKind.accept:
        // Only honour an accept for a request we actually sent.
        if (existing?.status == ContactStatus.pendingOutgoing) {
          await _setStatus(m.src, ContactStatus.accepted);
          // The durable-frame gate above only acks ACCEPTED senders — but an
          // accept is the very frame that CREATES that state, so the honoured
          // accept is acked here instead: the accepting side retires it from
          // its outbox. (A later duplicate finds us accepted and takes the
          // generic gate: re-acked + deduped there.)
          if (fid != null) {
            _outbox.remember(fid);
            await _ackFrame(m, fid);
          }
        } else {
          return;
        }
      case WireKind.message:
        // Consent gate: only deliver from accepted peers; drop the rest.
        if (existing?.status != ContactStatus.accepted) return;
        final id = env.id;
        if (isServiceEchoBody(env.body)) {
          if (id != null) await _ackTo(m, id, direct: true);
          return;
        }
        // The durable recommendation marker is reserved for the typed wire
        // kind. Refuse it on the ordinary text path so callers cannot bypass
        // campaign consent, rate limits and capability validation via sendText.
        if (isSpaceRecommendationMessageBody(env.body)) {
          if (id != null) await _ackTo(m, id, direct: true);
          return;
        }
        // [timeline] inbound receipt: id + whether it carried a reply path. id +
        // replyId only (no body) — lets us separate receive-latency from the ACK
        // round-trip when reading a session's logs.
        devLog(
          () =>
              'xVeil[timeline]: recv id=$id replyId=${m.replyId} '
              't=${DateTime.now().millisecondsSinceEpoch}',
        );
        // Dedup re-sent messages (the sender's local outbox re-sends un-acked
        // ones): if we already have this id, just re-ack so they stop.
        if (id != null && await _hasMessage(m.src, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        // Deniability: if we DELETED this message, a re-delivery must NOT
        // resurrect it. Re-ack so the sender stops re-sending, then drop.
        if (id != null && await _storage.isMessageDeleted(m.src.hex, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        // The peer's edit/delete of this message may have DRAINED FIRST (mailbox
        // blobs are unordered): when they sent then edited/unsent it while we
        // were offline, both deposits arrive on reconnect in arbitrary order.
        final pending = id == null ? null : _mutations.takePending(m.src, id);
        if (pending != null && pending.isDelete) {
          // Honor the unsend: store then tombstone so the message never shows AND
          // a later re-delivery is refused (isMessageDeleted above) — deniable
          // erasure, not a transient hide. No notification for an unsent message.
          await _store(
            m.src,
            MessageDirection.incoming,
            env.body,
            MessageStatus.delivered,
            id: id,
            timestamp: _wireSentAt(env),
            customEmoji: env.customEmoji,
          );
          await _storage.deleteMessage(m.src.hex, id!);
          await _storage.scrubDeleted();
          await _ackTo(m, id, direct: true);
          return;
        }
        // Apply a buffered edit by storing the edited body directly, so the
        // latest text shows on first paint (no flash of the superseded text, and
        // the original body never hits the container — nothing to scrub).
        final body = pending?.body ?? env.body;
        await _store(
          m.src,
          MessageDirection.incoming,
          body,
          MessageStatus.delivered,
          id: id,
          timestamp: _wireSentAt(env),
          replyToId: env.replyTo,
          forwardedFrom: env.forwardedFrom,
          customEmoji: pending == null ? env.customEmoji : pending.customEmoji,
          // Fold under the SENDER's seq (R4) so the (author, seq) is identical on
          // both devices — the basis for gap detection. Null from an older sender
          // → storage allocates locally (no cross-device convergence for them).
          seq: env.seq,
        );
        _emitIncoming(m.src, body, isFile: false, messageId: id);
        if (id != null) {
          await _ackTo(m, id);
        }
      case WireKind.ack:
        // Consent gate, like every other inbound arm: only an accepted contact
        // can flip our message state. Without this any non-blocked peer could
        // ack an arbitrary (guessed) id to forge a "delivered" mark and cancel
        // our retry backoff in any conversation. A legit ack only comes from a
        // peer we already accepted (we send messages — hence acks — only to them).
        // The peer confirms delivery of our message [env.id] — stop re-sending.
        final ackId = env.id;
        if (existing?.status != ContactStatus.accepted) {
          if (ackId == null ||
              (!await _authorizedGroupCallAck(m.src, ackId) &&
                  !await _authorizedExternalSpaceProposalAck(m.src, ackId))) {
            return;
          }
        }
        if (ackId != null) {
          // Retire a durable control frame the peer just confirmed (sign, edit,
          // del, clear, accept, reconnect): stop re-driving + re-stashing it.
          // A no-op when ackId is an ordinary message id (not in the outbox).
          _retireOutboxFrame(ackId);
          // Idempotent: the peer's drain re-acks every cycle until its relay
          // blob ages out, so duplicate acks arrive in a storm. Mark delivered +
          // log + write storage only ONCE per id — re-doing it on every dup was
          // hammering the store (the user-visible "storage opens slowly").
          if (_messageDelivery.noteAck(m.src.hex, ackId)) {
            // [timeline] sender-side "delivered" moment — pair with the send t0
            // to get the full perceived round-trip. id + time only.
            devLog(
              () =>
                  'xVeil[timeline]: delivered id=$ackId '
                  't=${DateTime.now().millisecondsSinceEpoch}',
            );
            // Scope by the sender's conversation (m.src.hex) so the status can
            // only land on a message that lives in THIS peer's chat.
            await _storage.markMessageStatus(
              m.src.hex,
              ackId,
              MessageStatus.delivered,
            );
          }
        }
      case WireKind.edit:
        // The peer edited a message THEY sent us. Apply only to an INCOMING
        // message we hold from this peer — a peer must never be able to rewrite
        // our own outgoing messages (the id travels on the wire, so they know
        // it; the direction check is the real authorization gate).
        if (existing?.status != ContactStatus.accepted) return;
        await _mutations.applyIncomingEdit(m.src, env);
      case WireKind.del:
        // The peer unsent a message THEY sent us — purge + scrub our copy too.
        // Same authorization gate: only their incoming messages, never ours.
        if (existing?.status != ContactStatus.accepted) return;
        // Receiver policy: a contact we've forbidden from deleting-at-us has its
        // unsend DECLINED — our copy stays. Buffering is skipped too, so an
        // out-of-order del can't apply once the message lands. No oracle: the
        // peer is never told the delete was ignored.
        if (existing?.allowPeerDelete == false) return;
        final delId = env.id;
        if (delId == null) break;
        await _mutations.applyIncomingDelete(m.src, delId);
      case WireKind.sync:
        // Event-log gap-fill beacon (§15, 3c): the peer tells us what it holds
        // per author; we re-ship every event it is missing above its high-water.
        // Consent-gated (R2) — never reconcile a conversation with a non-accepted
        // node. We also beacon back so the peer heals OUR gaps in the same round.
        if (existing?.status != ContactStatus.accepted) return;
        await _handlePeerSync(m.src, env.body);
        return;
      case WireKind.voidSeq:
        // An inert seq placeholder from the peer's gap-fill: record the void slot
        // so our high-water for the peer's stream advances past a deleted/
        // superseded event it never delivered (renders nothing, no resurrection).
        if (existing?.status != ContactStatus.accepted) return;
        final vseq = env.seq;
        if (vseq != null) {
          await _storage.applyRemoteVoid(m.src.hex, m.src.hex, vseq);
        }
        return;
      case WireKind.clear:
        // The peer CLEARED the conversation up to a per-author seq watermark
        // (clear-for-everyone). Consent-gated (R2); the author is bound to the
        // AUTHENTICATED sender (R1, m.src). v1 policy: an accepted contact's clear
        // is APPLIED (the "delete for everyone" the sender intends) — a future
        // per-contact toggle can decline it; and once multi-device lands, a clear
        // from our OWN identity is authoritative for our devices the same way.
        if (existing?.status != ContactStatus.accepted) return;
        // Same receiver policy as del: a forbidden contact can't clear our copy.
        if (existing?.allowPeerDelete == false) return;
        final cseq = env.seq;
        if (cseq != null) {
          Map<String, int> wm;
          try {
            final raw = jsonDecode(env.body);
            wm = raw is Map
                ? raw.map((k, v) => MapEntry(k as String, v as int))
                : <String, int>{};
          } catch (_) {
            return; // malformed watermark → drop
          }
          await _storage.applyRemoteClear(m.src, m.src.hex, cseq, wm);
          _signal();
        }
        return;
      case WireKind.fileQuery:
        // A gap-fill probe for a file (§15 3c, resumable): the peer still holds
        // file <tid> and asks what we're missing. Reply with a fileNack naming
        // the gaps (or "all" if we hold no chunk yet). The peer then re-sends only
        // those chunks, instead of re-pushing the whole blob each round.
        if (existing?.status != ContactStatus.accepted) return;
        await _fileTransfer.handleQuery(m, parseFileMeta(env.body));
        return;
      case WireKind.fileNack:
        // The receiver lists the chunks it still needs of a file WE sent
        // (null = all). Re-send only those, rate-limited per (peer, transfer) so
        // a NACK flood can't drive a re-send storm.
        if (existing?.status != ContactStatus.accepted) return;
        final nack = parseFileNack(env.body);
        await _fileTransfer.handleNack(m.src, nack.transferId, nack.missing);
        return;
      case WireKind.reconnect:
        // "We were connected — re-establish." Treated exactly like a request: a
        // peer who wiped its chat data (Case-A) no longer holds us, so our normal
        // messages/beacons hit its consent gate and drop; this re-intros us so it
        // can re-accept. Disambiguated by OUR state in _handleRequestOrReconnect
        // (accepted→re-ack; unknown/pending→pending intro; blocked→already
        // dropped). Falls through to _signal() so the pending surfaces in the UI.
        await _handleRequestOrReconnect(m, env, existing?.status);
      case WireKind.fileStream:
        // Reserved abandoned push-stream prototype. No production sender ever
        // emitted this kind; the shipped any-size path is contentManifest + a
        // receiver-initiated content-id-bound pull stream. Reusing the same
        // accept loop for a pushed blob would create an ambiguous protocol and
        // bypass manifest/hash/opt-in checks, so legacy experimental frames stay
        // an authenticated, consent-gated silent drop. Keep the enum slot so all
        // later wire indices remain stable.
        if (existing?.status != ContactStatus.accepted) return;
        devLog(
          () =>
              'xVeil[recv]: reserved fileStream frame '
              '${parseFileMeta(env.body).transferId} — dropped',
        );
        return;
      case WireKind.contentManifest:
        // A peer advertises a content manifest (the "torrent"): verify it,
        // register a transfer, request the pieces we lack.
        final groupCid = _groupScopedManifestContentId(env.body);
        if (groupCid != null && _groupPullSourceAllowed(m.src, groupCid)) {
          // Compatibility with the preceding build, whose live group-holder
          // hint reused contentManifest. Check this before the contact gate:
          // co-members may also be accepted contacts, but the eventless,
          // exact-(peer,cid)-scoped hint must still avoid the 1:1 offer path.
          await _onGroupContentManifest(m.src, env.body);
          return;
        }
        if (existing?.status != ContactStatus.accepted) {
          devLog(
            () =>
                'xVeil[content]: manifest DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
        devLog(
          () =>
              'xVeil[content]: manifest frame ${env.body.length}B '
              '<- ${m.src.short}',
        );
        await _onContentManifest(m.src, env.body);
        return;
      case WireKind.groupContentManifest:
        // A live holder hint for an already-scoped group pull. The group
        // receive path validates the exact (peer,cid) scope and deliberately
        // creates no chat offer, auto-download, ACK, or membership oracle.
        await _onGroupContentManifest(m.src, env.body);
        return;
      case WireKind.contentReoffer:
        // A peer lost the manifest handle (restart) but still holds the offer —
        // re-advertise if we are still serving (or can re-open a durable source).
        if (existing?.status != ContactStatus.accepted) return;
        await _onContentReoffer(m.src, env.body);
        return;
      case WireKind.contentGone:
        // A holder answered a reoffer with "I no longer have those bytes" —
        // stop retrying against them and, once no source remains, surface the
        // terminal ask-for-a-re-send state instead of spinning forever.
        if (existing?.status != ContactStatus.accepted) return;
        await _onContentGone(m.src, env.body);
        return;
      case WireKind.pieceRequest:
        // A peer asks for pieces of content we serve — send the requested
        // pieces as chunks (paced).
        if (existing?.status != ContactStatus.accepted) return;
        _onPieceRequest(m.src, parsePieceRequest(env.body));
        return;
      case WireKind.pieceChunk:
        // One chunk of one piece: buffer + verify-on-complete; finish the
        // transfer when every piece is verified.
        if (existing?.status != ContactStatus.accepted) return;
        await _onPieceChunk(parsePieceChunk(env.body));
        return;
      case WireKind.signRequest:
        // A peer asks us to attest authorship of one of OUR messages. Consent-
        // gated; the policy (ask / auto / refuse) decides what happens next.
        if (existing?.status != ContactStatus.accepted) return;
        await _onSignRequest(m.src, env);
        return;
      case WireKind.signResponse:
        // The author answered our signature request — verify + record.
        if (existing?.status != ContactStatus.accepted) return;
        await _onSignResponse(m.src, env);
        return;
      case WireKind.callSignal:
        // Call control plane (voice/video/screen). Consent-gated; a durable
        // signal was already acked+deduped by the generic frame gate above.
        // Forward the decoded signal to the attached call service (dropped when
        // none is attached — e.g. a headless/loopback context).
        if (existing?.status != ContactStatus.accepted) return;
        final callSig = CallSignal.tryDecode(env.body);
        if (callSig != null) {
          devLog(() {
            final at = callSig.sentAtMs;
            final age = at == null
                ? 'n/a'
                : '${_now().millisecondsSinceEpoch - at}ms';
            return 'xVeil[call-sig]: in type=${callSig.type.name} '
                'call=${callSig.callId} from=${m.src.short} age=$age';
          });
          onCallSignal?.call(m.src, callSig);
        }
        return;
      case WireKind.p2pEndpoints:
        // A contact shared its direct dial endpoints (P2P epic). Consent-gated
        // at transport admission; the endpoint service re-checks the local P2P
        // policy (mutual consent) before acting on or answering it.
        if (existing?.status != ContactStatus.accepted) return;
        devLog(
          () =>
              'xVeil[p2p]: in endpoints from=${m.src.short} '
              '(${env.body.length} B)',
        );
        onP2PEndpoints?.call(m.src, env.body);
        return;
      case WireKind.spaceInvite:
        // A proposal, not authorization. Keep it contact-gated and let the
        // Space layer validate the authenticated sender and explicit target.
        if (existing?.status != ContactStatus.accepted) return;
        final inviteHandler = onSpaceInvite;
        if (inviteHandler == null) return;
        await inviteHandler(m.src, env.body);
        if (fid != null) {
          await _ackFrame(m, fid);
          _outbox.remember(fid);
        }
        return;
      case WireKind.spaceInviteDecision:
        // The authenticated invitee explicitly accepted/declined. The Space
        // layer matches it to a durable outgoing proposal before mutating
        // membership; an arbitrary decision frame grants nothing by itself.
        if (existing?.status != ContactStatus.accepted) return;
        final decisionHandler = onSpaceInviteDecision;
        if (decisionHandler == null) return;
        await decisionHandler(m.src, env.body);
        if (fid != null) {
          await _ackFrame(m, fid);
          _outbox.remember(fid);
        }
        return;
      case WireKind.spaceJoinRequest:
        // The opaque ticket capability replaces contact consent for this one
        // narrow frame. Persist+policy validation happens before ACK; invalid,
        // revoked, rate-limited and blocked requests receive no response.
        if (fid != null && _outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
        final joinRequestHandler = onSpaceJoinRequest;
        if (joinRequestHandler == null ||
            !await joinRequestHandler(m.src, env.body)) {
          return;
        }
        if (fid != null) {
          _outbox.remember(fid);
          await _ackFrame(m, fid);
        }
        return;
      case WireKind.spaceJoinDecision:
        // The requester already holds the exact outgoing request+ticket. The
        // decision is status only; a signed addMember snapshot remains the
        // sole authority for materialization.
        if (fid != null && _outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
        final joinDecisionHandler = onSpaceJoinDecision;
        if (joinDecisionHandler == null ||
            !await joinDecisionHandler(m.src, env.body)) {
          return;
        }
        if (fid != null) {
          _outbox.remember(fid);
          await _ackFrame(m, fid);
        }
        return;
      case WireKind.spaceModerationAppeal:
        // Like a public join request, this narrow external proposal carries
        // its own node-id-bound authorization. Persist only after the Space
        // owner validates the exact action and one-per-action admission rule.
        if (fid != null && _outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
        final appealHandler = onSpaceModerationAppeal;
        if (appealHandler == null || !await appealHandler(m.src, env.body)) {
          return;
        }
        if (fid != null) {
          _outbox.remember(fid);
          await _ackFrame(m, fid);
        }
        return;
      case WireKind.spaceModerationAppealDecision:
        if (fid != null && _outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
        final appealDecisionHandler = onSpaceModerationAppealDecision;
        if (appealDecisionHandler == null ||
            !await appealDecisionHandler(m.src, env.body)) {
          return;
        }
        if (fid != null) {
          _outbox.remember(fid);
          await _ackFrame(m, fid);
        }
        return;
      case WireKind.spaceAbuseReport:
        // This external proposal is deliberately not contact-gated. The
        // Space layer binds it to the authenticated reporter, exact retained
        // content, current owner route and per-reporter quota before ACK.
        if (fid != null && _outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
        final abuseReportHandler = onSpaceAbuseReport;
        if (abuseReportHandler == null ||
            !await abuseReportHandler(m.src, env.body)) {
          return;
        }
        if (fid != null) {
          _outbox.remember(fid);
          await _ackFrame(m, fid);
        }
        return;
      case WireKind.spaceAbuseReportDecision:
        if (fid != null && _outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
        final abuseDecisionHandler = onSpaceAbuseReportDecision;
        if (abuseDecisionHandler == null ||
            !await abuseDecisionHandler(m.src, env.body)) {
          return;
        }
        if (fid != null) {
          _outbox.remember(fid);
          await _ackFrame(m, fid);
        }
        return;
      case WireKind.spaceRecommendation:
        // A card is still a user-visible 1:1 message, so contact consent,
        // message-id dedup, deletion tombstones and ACK semantics all apply.
        if (existing?.status != ContactStatus.accepted) return;
        final id = env.id;
        if (id == null) return;
        if (await _hasMessage(m.src, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        if (await _storage.isMessageDeleted(m.src.hex, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        final SpaceRecommendationCard? card;
        try {
          card = SpaceRecommendationCard.fromJson(jsonDecode(env.body));
        } catch (_) {
          return;
        }
        if (card == null) return;
        try {
          final ticket = SpaceJoinCode.parse(card.joinCode);
          if (ticket.spaceId != card.spaceId ||
              ticket.isExpiredAt(_now().millisecondsSinceEpoch)) {
            await _ackTo(m, id, direct: true);
            return;
          }
        } catch (_) {
          await _ackTo(m, id, direct: true);
          return;
        }
        if (!await spaceRecommendationsEnabled()) {
          // Receiver opt-out is intentionally silent: ACK and discard so the
          // sender gets no preference oracle and retries cannot create spam.
          await _ackTo(m, id, direct: true);
          return;
        }
        final recommendationGate = onSpaceRecommendation;
        if (recommendationGate != null &&
            !await recommendationGate(m.src, card)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        await _store(
          m.src,
          MessageDirection.incoming,
          encodeSpaceRecommendationMessage(card),
          MessageStatus.delivered,
          id: id,
          timestamp: _wireSentAt(env),
          seq: env.seq,
        );
        _emitIncoming(m.src, 'Community: ${card.name}', isFile: false);
        await _ackTo(m, id);
        return;
      case WireKind.reaction:
        // The peer reacted to a message in THIS conversation. A side annotation
        // (not an event-log event); the durable frame was already acked+deduped
        // by the generic gate above. Reactor = the authenticated sender.
        if (existing?.status != ContactStatus.accepted) return;
        final targetId = env.id;
        if (targetId == null) return;
        await _applyReaction(m.src.hex, targetId, m.src.hex, env.body);
        _signal();
        return;
      case WireKind.groupEntry:
        // A group snapshot from a member (groups epic); the durable frame was
        // already acked+deduped above. From an accepted contact it ingests as
        // always; from a NON-contact it goes through the guarded stranger
        // path (existing group + sender is a member — scale-free log sync).
        if (existing?.status == ContactStatus.accepted) {
          onGroupEntry?.call(m.src, env.body);
        } else {
          onGroupEntryFromStranger?.call(m.src, env.body);
        }
        return;
      case WireKind.groupEntryChunk:
        // One slice of an oversized snapshot (inline group media). Already
        // acked/deduped above. Reassemble by transferId; once every chunk is
        // present, ingest the joined bundle exactly like a whole groupEntry.
        // A NON-contact's chunk must pass the membership admission BEFORE any
        // reassembly RAM is spent on it.
        if (existing?.status == ContactStatus.accepted) {
          _ingestGroupChunk(m.src, env.body);
        } else {
          await _ingestStrangerGroupChunk(m.src, env.body);
        }
        return;
      case WireKind.groupContentRequest:
        // A signed membership-authorized fetch request (groups content path).
        // Deliberately NOT contact-gated: the signature + membership proof
        // inside is the authorization; the group layer verifies against its
        // own folded state and grants (or silently drops — no oracle).
        onGroupContentRequest?.call(m.src, env.body);
        return;
      case WireKind.groupContentReceipt:
        // Live-only proof that this authenticated requester completed one
        // exact signed request. The group layer requires the source-bound,
        // single-use RAM challenge and current authorization. Never ACK:
        // a response would create both a membership oracle and a durable read
        // receipt surface.
        onGroupContentReceipt?.call(m.src, env.body);
        return;
      case WireKind.spacePublicFeedRequest:
        // Live-only and contact-independent. The Space layer binds the signed
        // requester to this authenticated source, applies a RAM-only quota and
        // serves only hashes committed by its verified descriptor/manifest.
        await onSpacePublicFeedRequest?.call(m.src, env.body);
        return;
      case WireKind.spacePublicFeedChunk:
        // No ACK or unsolicited allocation: the Space layer accepts this only
        // for an exact pending (holder, nonce, Space, manifest, object) tuple.
        onSpacePublicFeedChunk?.call(m.src, env.body);
        return;
      case WireKind.spacePublicMediaGrantRequest:
        // Public readers are not members. The Space layer may mint only one
        // short-lived `(authenticated source, CID)` content-stream grant after
        // matching the signed request to an exact verified public projection.
        // No ACK/outbox/chat row: denial is intentionally silent.
        await onSpacePublicMediaGrantRequest?.call(m.src, env.body);
        return;
      case WireKind.groupCallSignal:
        // No contact gate: current group membership + epoch AEAD + node-bound
        // signature are the authorization. Invalid/removed/stale senders are
        // silently dropped by the group layer (no membership/read oracle).
        final accepted =
            await onGroupCallSignal?.call(m.src, env.body) ?? false;
        if (accepted && fid != null) {
          await _ackFrame(m, fid);
          _outbox.remember(fid);
        }
        return;
      case WireKind.chatDeleted:
        // The peer deleted this conversation on their device and explicitly
        // opted into telling us. Accepted contacts only (a stranger/pending
        // peer gets the usual silent drop — no oracle); the durable frame was
        // already acked+deduped by the generic gate above. Leave a LOCAL
        // system-notice marker in the chat via the normal store path, so
        // unread/notification behave like any incoming event.
        if (existing?.status != ContactStatus.accepted) return;
        await _store(
          m.src,
          MessageDirection.incoming,
          kChatDeletedMarkerBody,
          MessageStatus.delivered,
          // Fall back to receive time: an unstamped marker would sort into
          // the middle of the chat instead of closing it.
          timestamp: _wireSentAt(env) ?? _now(),
          // A LOCAL annotation, not an event from the sender's (just wiped)
          // log — see [_store.selfAuthored] for the ordering rationale.
          selfAuthored: true,
        );
        _emitIncoming(m.src, '🗑️', isFile: false);
        return;
      case WireKind.cloudDocument:
        if (existing?.status != ContactStatus.accepted) return;
        if (await _deliverCloudDocumentFrame(m.src, env.body)) {
          await _ackTerminalDocumentFrame(m, fid);
        }
        return;
      case WireKind.cloudDocumentChunk:
        if (existing?.status != ContactStatus.accepted) return;
        await _ingestCloudDocumentChunk(m, env.body, fid);
        return;
      case WireKind.unknown:
        // A structured (v:2) frame from a NEWER build whose kind we don't know —
        // the decoder already mapped it to this drop sentinel (RULE WC). Ignore.
        return;
      case WireKind.fileMeta:
        if (existing?.status != ContactStatus.accepted) {
          devLog(
            () =>
                'xVeil[recv]: fileMeta DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
        await _fileTransfer.handleMeta(m, parseFileMeta(env.body));
        return;
      case WireKind.fileChunk:
        if (existing?.status != ContactStatus.accepted) {
          devLog(
            () =>
                'xVeil[recv]: fileChunk DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
        await _fileTransfer.handleChunk(m, parseFileChunk(env.body));
        return;
    }
    _signal();
  }
}
