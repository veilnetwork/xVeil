part of 'messaging_core.dart';

/// Admission and fetch bootstrap for authenticated content advertisements.
///
/// Manifest validation, offer surfacing and auto-download policy stay
/// serialized with the owning [MessagingService] state.
extension _MessagingContentReceive on MessagingService {
  Future<void> _onContentManifest(NodeId peer, String body) async {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final ref = _parseContentManifestRef(decoded);
    if (ref != null) {
      await _onContentManifestRef(peer, ref);
      return;
    }
    final m = ContentManifest.fromJson(decoded);
    if (m == null) {
      devLog(
        () => 'xVeil[content]: manifest DROPPED (malformed) <- ${peer.short}',
      );
      return; // malformed / not self-consistent → untrusted, drop
    }
    devLog(
      () =>
          'xVeil[content]: manifest parsed ${m.contentId.substring(0, 12)} '
          'pieces=${m.pieceCount} msg=${m.msgId?.substring(0, 8)} '
          '<- ${peer.short}',
    );
    // Surface the file as an OFFER first — metadata only (name/size + the
    // contentId to fetch), NO blob yet — idempotent on the sender's per-send
    // msgId. The receiver decides whether to download (anti-spam + disk control).
    await _surfaceFileOffer(peer, m, route: 'manifest');

    // We ALREADY hold these exact bytes (a re-offer / dedup) → the offer renders
    // as downloaded; ack so the sender flips sent->delivered.
    if (await _storage.hasFile(m.contentId)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} ALREADY HELD '
            '<- ${peer.short} (no re-download)',
      );
      // No signal here: nothing on this side changed. The offer either just
      // surfaced (and that path signals when it stores a row) or was already
      // there. A holder re-advertises the same content repeatedly, so signalling
      // per re-offer poked the chat list into a rebuild for a no-op — which is
      // what a redraw with no visible cause looks like.
      await _send(peer, WireEnvelope.ack(m.msgId ?? m.contentId).encode());
      return;
    }
    // Already pulling it (a re-advertise mid-download) → keep the latest identity.
    //
    // This was the one branch here that returned in SILENCE, and it is the one
    // that decides a re-advertised offer will not start a download. On the
    // stand a file sat undelivered while its offer was re-sent 94 times, and
    // the log could not say whether the handler skipped it here, held it
    // already, or fell through to the policy. Say it.
    if (_contentFetching.refreshManifest(peer, m)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} re-advertised '
            'while a fetch is ALREADY ACTIVE <- ${peer.short} — refreshed, not '
            'restarted',
      );
      return;
    }
    // Retain the manifest so the user (or auto-download) can fetch on demand.
    _contentAvailability.rememberManifest(peer, m);

    // A fresh manifest proves the content is obtainable again — clear any
    // terminal "gone" mark before the resume driver looks at it.
    unawaited(_clearContentGone(m.contentId));
    // A durable (cross-restart) pending download exists for this content and
    // the holder just proved it's online — nudge the auto-resume driver.
    unawaited(_resumeOnOfferSignal(m.contentId, manifest: m));

    // A user download was PARKED waiting for this manifest (re-advertise after a
    // restart) → start it now with its destination (sink for unencrypted-to-file,
    // null for the encrypted tier), regardless of the auto-download policy.
    if (_contentAvailability.hasPending(m.contentId)) {
      final sink = _contentAvailability.takePending(m.contentId);
      devLog(
        () =>
            'xVeil[content]: re-advertised manifest arrived for '
            '${m.contentId.substring(0, 12)} — resuming the parked download',
      );
      final retryPeers = await _contentSourcePeers(
        preferred: peer,
        contentId: m.contentId,
      );
      if (sink != null) {
        // Explicit "save plaintext to this path" intent — stream it (default;
        // see _plainFileStreamDartDefine). The piece/chunk fetch below stays
        // as the automatic fallback when no stream can be opened at all.
        if (_plainFileStream &&
            await _pullSwarmStreamToFile(
              peer,
              m.contentId,
              m,
              retryPeers,
              sink,
              _fetchSavePath[m.contentId] ?? m.contentId,
            )) {
          return;
        }
        await _beginFetch(peer, m, sink: sink);
        return;
      } else {
        if (await _pullSwarmStream(peer, m.contentId, m, retryPeers)) {
          return;
        }
        if (await _pullStream(
          peer,
          m.contentId,
          null,
          retryPeers: retryPeers,
        )) {
          return;
        }
      }
      await _beginFetch(peer, m, sink: sink);
      return;
    }

    // A plaintext save/download has already been explicitly requested for this
    // content id (for example by the desktop save dialog or the soak hook).
    // Do not let the automatic encrypted-tier fetch race it: if auto-download
    // wins, the UI may mark the offer as downloaded while the user's chosen
    // destination file remains empty and waits forever for a savedPath
    // completion event.
    if (_fetchSavePath.containsKey(m.contentId)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            'plain-file download pending — suppressing auto-download',
      );
      return;
    }

    if (_filePolicy.allowsAuto(m.size, m.name)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            '(${m.size}B "${m.name}") <- ${peer.short} — auto-downloading (<= cap)',
      );
      await _beginFetch(peer, m);
    } else {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            '(${m.size}B "${m.name}") <- ${peer.short} — OFFERED (awaiting user)',
      );
    }
  }

  /// Parse and retain a holder advertisement that arrived through the
  /// membership-scoped group reply path. Unlike a normal 1:1 offer this must
  /// not materialise a direct-chat row, auto-download, or emit an ACK/read
  /// oracle. The already-running group fetch consumes the hint and still
  /// verifies the full content-addressed manifest and every piece.
  Future<void> _onGroupContentManifest(NodeId peer, String body) async {
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final ref = _parseContentManifestRef(decoded);
    if (ref != null) {
      final cid = ref.contentId;
      if (!_groupPullSourceAllowed(peer, cid)) return;
      _contentAvailability.rememberRef(peer, ref);
      _warmStreamPeer(peer);
      devLog(
        () =>
            'xVeil[content]: group holder ref '
            '${cid.substring(0, 12)} <- ${peer.short}',
      );
      unawaited(_clearContentGone(cid));
      return;
    }
    final manifest = ContentManifest.fromJson(decoded);
    if (manifest == null ||
        !_groupPullSourceAllowed(peer, manifest.contentId)) {
      return;
    }
    _rememberOfferedManifest(peer, manifest);
    _warmStreamPeer(peer);
    devLog(
      () =>
          'xVeil[content]: group holder manifest '
          '${manifest.contentId.substring(0, 12)} <- ${peer.short}',
    );
    unawaited(_clearContentGone(manifest.contentId));
  }

  String? _groupScopedManifestContentId(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final ref = _parseContentManifestRef(decoded);
      // Compatibility with a holder from the immediately preceding build,
      // which used the ordinary contentManifest kind for this live hint.
      // Real direct-chat file sends carry a per-send event id; only an
      // eventless base manifest/ref may be reclassified while the exact group
      // pull scope is active.
      if (ref != null) return ref.msgId == null ? ref.contentId : null;
      final manifest = ContentManifest.fromJson(decoded);
      return manifest?.msgId == null ? manifest?.contentId : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _onContentManifestRef(
    NodeId peer,
    _ContentManifestRef ref,
  ) async {
    final cid = ref.contentId;
    devLog(
      () =>
          'xVeil[content]: manifest ref parsed ${cid.substring(0, 12)} '
          'size=${ref.size} msg=${ref.msgId?.substring(0, 8)} '
          '<- ${peer.short}',
    );
    await _surfaceFileOfferFields(
      peer,
      route: 'ref',
      contentId: cid,
      name: ref.name,
      size: ref.size,
      msgId: ref.msgId,
      seq: ref.seq,
      ts: ref.ts,
      thumb: ref.thumb,
    );

    if (await _storage.hasFile(cid)) {
      devLog(
        () =>
            'xVeil[content]: ${cid.substring(0, 12)} ALREADY HELD '
            '<- ${peer.short} (manifest ref only)',
      );
      await _send(peer, WireEnvelope.ack(ref.msgId ?? cid).encode());
      _signal();
      return;
    }
    _contentAvailability.rememberRef(peer, ref);
    // A fresh ref proves the content is obtainable again.
    unawaited(_clearContentGone(cid));
    // A durable pending download exists and its holder just showed up online.
    unawaited(_resumeOnOfferSignal(cid));
    if (_contentAvailability.hasPending(cid)) {
      unawaited(_resumePendingFromManifestRef(peer, cid, ref));
      return;
    }
    if (_fetchSavePath.containsKey(cid)) {
      devLog(
        () =>
            'xVeil[content]: ${cid.substring(0, 12)} '
            'plain-file download pending — waiting stream manifest',
      );
      return;
    }
    if (_filePolicy.allowsAuto(ref.size, ref.name)) {
      unawaited(_beginFetchFromManifestRef(peer, cid, ref, null, null));
    } else {
      devLog(
        () =>
            'xVeil[content]: ${cid.substring(0, 12)} '
            '(${ref.size}B "${ref.name}") <- ${peer.short} — '
            'OFFERED via manifest-ref',
      );
    }
  }

  /// Register a fetch for [m] + request all its pieces. Evicts any abandoned
  /// reassembler first (RAM bound). [sink] (non-null) diverts each verified piece
  /// to a plaintext file the user picked, instead of the Storage port. Shared by
  /// auto-download and [downloadContent]/[downloadContentToFile].
  Future<void> _beginFetch(
    NodeId peer,
    ContentManifest m, {
    _FetchSink? sink,
  }) async {
    if (_disposed || _cancelledDownloads.contains(m.contentId)) {
      try {
        await sink?.close();
      } catch (_) {}
      return;
    }
    // Expire before checking this same content id. Previously a stale fetch
    // matched here forever, so a retry was parked behind an abandoned
    // reassembler and its plaintext sink handle was leaked.
    await _contentFetching.evictStale();
    final existing = _contentFetching.active(m.contentId);
    if (existing != null) {
      if (sink != null) {
        if (existing.sink == null) {
          _contentAvailability.holdPending(m.contentId, sink);
          devLog(
            () =>
                'xVeil[content]: plain-file save parked for '
                '${m.contentId.substring(0, 12)} — export after active fetch',
          );
        } else {
          await sink.close(); // already fetching to a plaintext sink
        }
      }
      return;
    }
    _contentFetching.add(
      m.contentId,
      manifest: m,
      xfer: ContentTransfer(m),
      peer: peer,
      name: m.name,
      sink: sink,
    );
    _ensureContentTimer();
    await _send(
      peer,
      pieceRequestEnvelope(contentId: m.contentId, indices: null).encode(),
    );
  }
}
