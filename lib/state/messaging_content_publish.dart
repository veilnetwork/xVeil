part of 'messaging_core.dart';

/// Sender-side content publication and durable offer construction.
///
/// This keeps hashing, content-addressed persistence, advertisement and
/// source-backed streaming in one auditable path while [MessagingService]
/// remains the public facade.
extension _MessagingContentPublish on MessagingService {
  /// Persist [bytes] as a streamed (uncapped) blob keyed by the manifest's
  /// contentId — the SAME on-disk piece layout the receiver builds — so the
  /// sender SERVES it from disk ([readFileRange]) without holding it in RAM and
  /// without the whole-file [storeFile] cap (which is what bounded send size).
  /// Idempotent: a blob already present (a re-send / re-advertise of identical
  /// bytes) is left as-is, so the de-dup store happens at most once.
  Future<void> _storeServedBlob(
    ContentManifest manifest,
    Uint8List bytes,
  ) async {
    final cid = manifest.contentId;
    if (await _storage.hasFile(cid)) return;
    for (var p = 0; p < manifest.pieceCount; p++) {
      final start = p * manifest.pieceSize;
      final end = start + manifest.pieceLength(p);
      await _storage.storeFilePiece(
        cid,
        p,
        manifest.pieceCount,
        manifest.pieceSize,
        bytes.length,
        Uint8List.sublistView(bytes, start, end),
        name: manifest.name,
      );
    }
  }

  /// Register [manifest] for serving and advertise it to [dst]. The bytes are
  /// read on request either from [source] (a large send, served straight from the
  /// user's original file) or — when [source] is null — from the on-disk blob
  /// store keyed by contentId. Shared tail of every advertise path. A prior
  /// [source] for this contentId is closed if we replace it (no leaked handle).
  static const int _contentManifestInlineEnvelopeLimit = 5600;

  String _contentManifestJson(ContentManifest manifest) =>
      jsonEncode(manifest.toJson());

  String _contentManifestRefJson(ContentManifest manifest) => jsonEncode({
    'ref': 1,
    'id': manifest.contentId,
    'name': manifest.name,
    'size': manifest.size,
    if (manifest.msgId != null) 'mid': manifest.msgId,
    if (manifest.author != null) 'au': manifest.author,
    if (manifest.seq != null) 'sq': manifest.seq,
    if (manifest.ts != null) 'mts': manifest.ts,
    // Embedded micro-thumb (unbound, budget-bound at generation) — rides the
    // ref too so an over-limit full manifest still delivers the preview.
    if (manifest.thumbB64 != null) 'th': manifest.thumbB64,
  });

  _ContentManifestRef? _parseContentManifestRef(Map<String, dynamic> j) {
    try {
      if (j['ref'] != 1) return null;
      final id = j['id'] as String;
      final name = j['name'] as String;
      final size = j['size'] as int;
      if (id.length != 64 || size < 0) return null;
      return (
        contentId: id,
        name: name,
        size: size,
        msgId: j['mid'] as String?,
        author: j['au'] as String?,
        seq: j['sq'] as int?,
        ts: j['mts'] as int?,
        thumb: j['th'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Live-send the manifest frame for [manifest] and return the exact bytes
  /// sent (inline full manifest when it fits, else the compact ref frame) so
  /// the caller can also deposit them for offline delivery.
  Future<Uint8List> _sendContentManifest(
    NodeId dst,
    ContentManifest manifest,
  ) => _sendEncodedContentManifest(dst, manifest, groupScoped: false);

  Future<Uint8List> _sendGroupContentManifest(
    NodeId dst,
    ContentManifest manifest,
  ) => _sendEncodedContentManifest(dst, manifest, groupScoped: true);

  Future<Uint8List> _sendEncodedContentManifest(
    NodeId dst,
    ContentManifest manifest, {
    required bool groupScoped,
  }) async {
    final encoded = _encodeContentManifest(manifest, groupScoped: groupScoped);
    await _send(dst, encoded.frame);
    final scope = groupScoped ? 'group holder' : 'manifest';
    if (encoded.inline) {
      devLog(
        () =>
            'xVeil[content]: $scope inline '
            '${manifest.contentId.substring(0, 12)} '
            'frame=${encoded.frame.length}B -> ${dst.short}',
      );
    } else {
      devLog(
        () =>
            'xVeil[content]: $scope ref '
            '${manifest.contentId.substring(0, 12)} '
            'full_frame=${encoded.fullLength}B '
            'ref_frame=${encoded.frame.length}B -> ${dst.short}',
      );
    }
    return encoded.frame;
  }

  ({Uint8List frame, int fullLength, bool inline}) _encodeContentManifest(
    ContentManifest manifest, {
    bool groupScoped = false,
  }) {
    final fullJson = _contentManifestJson(manifest);
    final fullFrame =
        (groupScoped
                ? groupContentManifestEnvelope(fullJson)
                : contentManifestEnvelope(fullJson))
            .encode();
    if (fullFrame.length <= _contentManifestInlineEnvelopeLimit) {
      return (frame: fullFrame, fullLength: fullFrame.length, inline: true);
    }
    final refJson = _contentManifestRefJson(manifest);
    final refFrame =
        (groupScoped
                ? groupContentManifestEnvelope(refJson)
                : contentManifestEnvelope(refJson))
            .encode();
    return (frame: refFrame, fullLength: fullFrame.length, inline: false);
  }

  Future<void> _advertiseStored(
    NodeId dst,
    ContentManifest manifest, {
    ServeSource? source,
  }) async {
    final cid = manifest.contentId;
    final serveManifest = _baseContentManifest(manifest);
    final prev = _serving[cid];
    if (prev?.source != null &&
        source != null &&
        !_sameServeSource(prev!.source!, source)) {
      _retireServeSourceForContent(cid, prev.source!);
    } else if (prev?.source != null && source == null) {
      _retireServeSourceForContent(cid, prev!.source!);
    }
    _serving[cid] = (manifest: serveManifest, source: source, servedAt: _now());
    await _persistServeManifest(serveManifest);
    _evictServing();
    _ensureContentTimer();
    final mid = manifest.msgId;
    Uint8List frame;
    Object? liveError;
    StackTrace? liveStack;
    try {
      frame = await _sendContentManifest(dst, manifest);
    } catch (error, stack) {
      // A dead live route is exactly when the mailbox copy matters. Build the
      // same frame locally and persist it before returning; the previous order
      // threw before `_maybeStash`, making the documented offline fallback a
      // false guarantee.
      frame = _encodeContentManifest(manifest).frame;
      liveError = error;
      liveStack = stack;
    }
    // Offline fallback for the OFFER itself. The manifest was previously
    // live-only: on a flaky/down live path a plain text (which stashes) still
    // arrived while the file offer silently vanished — the reported "file
    // never came, other messages did". Deposit the exact manifest frame at the
    // recipient's mailbox, keyed by THIS send's msgId so a live + drained copy
    // dedup by event identity. Only for real event sends (msgId present) — the
    // bare content API advertises without an event and must not spam mailboxes.
    // Best-effort + non-blocking, exactly like the text path.
    if (mid != null) {
      if (liveError == null) {
        _stashInBackground(dst, 'mf:$mid', frame);
      } else {
        await _maybeStash(dst, 'mf:$mid', frame);
      }
    } else if (liveError != null) {
      Error.throwWithStackTrace(liveError, liveStack!);
    }
    devLog(
      () =>
          'xVeil[content]: advertise ${manifest.contentId.substring(0, 12)} '
          '(${manifest.pieceCount} pieces'
          '${mid != null ? ', msg ${mid.substring(0, 8)}' : ''}) -> ${dst.short}',
    );
  }

  /// The OFFER frame to re-advertise for an un-acked outgoing file message, or
  /// null when this message has no offer that could be re-sent.
  ///
  /// Re-driving a file message means re-sending the MANIFEST — the few hundred
  /// bytes that NAME the content — and never the content itself, which the
  /// recipient pulls on its own terms. Null is therefore the safe answer, and
  /// it is the answer for a small inline file: its bytes travelled as
  /// fileMeta + fileChunk and it has no manifest at all. So "no manifest, no
  /// re-offer" is what keeps a retry from ever becoming a byte re-push — the
  /// cost that the blanket file exclusion used to avoid by giving up on file
  /// offers entirely.
  Future<Uint8List?> _fileOfferRetryFrame(Message message) async {
    // Sender-side a large send records fileId = contentId; fileContentId is the
    // receiver's "offered, not downloaded" spelling. Same order as
    // [_manifestForPeerOffer] reads them.
    final cid = message.fileContentId ?? message.fileId;
    if (cid == null) return null;
    // Live serve entry first, then the durable `mf:$cid` blob so an offer still
    // re-drives after a restart. Both bind the id they were stored under, so a
    // small file's UUID can never resolve to somebody else's manifest.
    final manifest =
        _serving[cid]?.manifest ?? await _loadPersistedManifest(cid);
    if (manifest == null) return null;
    // Re-bind THIS message's event identity rather than whichever send last
    // occupied `_serving[cid]`: one blob may be offered to several contacts,
    // and the copy that finally arrives must fold into the event being retried.
    return _encodeContentManifest(
      _baseContentManifest(manifest).withEvent(
        msgId: message.id,
        author: message.author,
        seq: message.seq,
        ts: message.timestamp.millisecondsSinceEpoch,
        thumbB64: message.thumb,
      ),
    ).frame;
  }

  /// Parsed `served:$cid` record. Legacy records are a bare path string; new
  /// ones are JSON `{path,size,pieceSize,name,roots}` so the manifest can be
  /// rebuilt from the source file when the mf: blob is missing (its persist
  /// dies first on a bloated store — IndexFull).
  ///
  /// `roots` are the folders that AUTHORIZED the send, and their presence is
  /// what marks a record as delegated rather than user-picked. Empty means a
  /// person chose this file in this app and no grant gates it.
  _ServedRecord? _parseServedRecord(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith('{')) {
      return (
        path: raw,
        size: null,
        pieceSize: null,
        name: null,
        roots: const <String>[],
      );
    }
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final path = m['path'] as String?;
      if (path == null || path.isEmpty) return null;
      final roots = m['roots'];
      return (
        path: path,
        size: (m['size'] as num?)?.toInt(),
        pieceSize: (m['pieceSize'] as num?)?.toInt(),
        name: m['name'] as String?,
        roots: roots is List
            ? List<String>.unmodifiable(roots.whereType<String>())
            : const <String>[],
      );
    } catch (_) {
      return null;
    }
  }

  /// Rebuild the manifest of a durable offer by re-hashing the source file at
  /// [rec]'s path (one RAM-bounded pass — the same work the original send
  /// did, ~150 ms for 20 MB). Used when the mf: blob is missing: its persist
  /// is the first casualty of a bloated store (IndexFull), and without this a
  /// restarted sender answered UNSERVED/GONE forever while the bytes sat on
  /// disk. Returns null when the record lacks hashing params (legacy bare
  /// path), the file is gone, or its bytes changed (contentId mismatch).
  Future<ContentManifest?> _rebuildManifestFromServedRecord(
    String cid,
    _ServedRecord rec,
  ) async {
    final opener = sourceOpener;
    final size = rec.size;
    final pieceSize = rec.pieceSize;
    if (opener == null || size == null || pieceSize == null) return null;
    final src = await opener(rec.path);
    if (src == null) return null;
    try {
      final m = await ContentManifest.fromReader(
        name: rec.name ?? 'file',
        size: size,
        pieceSize: pieceSize,
        chunkBytes: MessagingService._contentChunkBytes,
        readRange: src.read,
      );
      if (m.contentId != cid) {
        devLog(
          () =>
              'xVeil[content]: served source at ${rec.path} no longer '
              'matches ${cid.substring(0, 12)} — treating as gone',
        );
        return null;
      }
      devLog(
        () =>
            'xVeil[content]: manifest rebuilt from source for '
            '${cid.substring(0, 12)} (${m.pieceCount} pieces)',
      );
      unawaited(_persistServeManifest(m)); // best-effort re-persist
      return m;
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: manifest rebuild failed for '
            '${cid.substring(0, 12)}: $e',
      );
      return null;
    } finally {
      try {
        await src.close();
      } catch (_) {}
    }
  }

  /// Whether the file behind the durable record still holds the bytes [cid]
  /// names — re-hashed, not assumed.
  ///
  /// A `served:$cid` record is a PATH. `sourceOpener` takes a path. Between
  /// the send that wrote the record and the pull that reopens it there is no
  /// check at all: the manifest came from `mf:$cid` and the bytes came from
  /// whatever the name pointed at by then. Replace the file after the send and
  /// every later fetch handed out the new one under the old content id, with a
  /// manifest that described the old (audit X-02). No race was required —
  /// which is what made it worse than the racy half.
  ///
  /// The check is one RAM-bounded hashing pass (what
  /// [_rebuildManifestFromServedRecord] already did for a different reason),
  /// so the verdict is cached against the file's size and mtime and re-taken
  /// as soon as either moves.
  ///
  /// DETECTION, NOT PREVENTION. Dart offers no `openat`, no `O_NOFOLLOW` and no
  /// `fstat`, so there is no way from here to bind the check and the open to
  /// the same descriptor; this project has hit that wall before and chose
  /// detection deliberately. What this does close is the case that needed no
  /// timing at all.
  ///
  /// The cache key used to be size and mtime, both writable by whoever can
  /// write the file — so the detector could be defeated outright by `truncate`
  /// plus `touch -r`, no race required, and the planted file inherited the
  /// cached "verified" verdict and was served without being hashed. The key now
  /// carries `(st_dev, st_ino)` as well, which is not something an attacker
  /// gets to choose.
  Future<bool> _servedSourceStillMatches(
    String cid,
    _ServedRecord rec,
  ) async {
    final stamp = await veilSourceStamp(rec.path);
    if (stamp != null) {
      final cached = _contentServing.servedVerdicts[cid];
      // All four, identity first. Matching size and mtime is what an attacker
      // can arrange; matching (device, inode) is what they cannot.
      if (cached != null &&
          cached.deviceId == stamp.deviceId &&
          cached.inode == stamp.inode &&
          cached.size == stamp.size &&
          cached.mtimeMs == stamp.mtimeMs) {
        return cached.ok;
      }
    }
    final pending = _contentServing.servedVerifications[cid];
    if (pending != null) return pending;
    final run = _verifyServedSource(cid, rec, stamp);
    _contentServing.servedVerifications[cid] = run;
    try {
      return await run;
    } finally {
      _contentServing.servedVerifications.remove(cid);
    }
  }

  Future<bool> _verifyServedSource(
    String cid,
    _ServedRecord rec,
    VeilSourceStamp? before,
  ) async {
    // A rebuild that returns non-null has already compared contentIds. It also
    // re-persists `mf:$cid`, so the pass costs at most one extra read even on
    // the missing-manifest path that would otherwise hash again right after.
    final ok = (await _rebuildManifestFromServedRecord(cid, rec)) != null;

    // Only cache a verdict this file can be held to. Two ways it cannot be:
    //
    //  * the file moved under the hashing pass — the stamp then describes
    //    something other than what was read (and the pass itself is already
    //    suspect, which is why the answer stands but is not remembered);
    //  * its mtime is younger than the coarsest filesystem tick, so a LATER
    //    write could still land under the SAME stamp and the verdict would
    //    never be re-taken.
    //
    // Skipping the cache costs a re-hash. Caching a stamp that cannot change
    // costs correctness, which is the whole point of the check.
    final after = await veilSourceStamp(rec.path);
    if (before == null || after == null || before != after) return ok;
    final settledFor = DateTime.now().millisecondsSinceEpoch - after.mtimeMs;
    if (settledFor < _MessagingContentServing.stampSettleMs) return ok;
    _contentServing.noteServedVerdict(cid, after, ok);
    return ok;
  }

  /// Whether the grant this durable offer was made under still holds.
  ///
  /// A record with no roots was made by a person picking a file in this app;
  /// nothing external gates it and nothing is asked. A record WITH roots was
  /// made on someone else's behalf, and its right to keep serving expires with
  /// their grant — so this is re-asked on every reopen and never cached. A
  /// revoke that takes effect when a cache happens to expire is not a revoke.
  ///
  /// Fails CLOSED: a delegated offer with no authorizer left to ask is a grant
  /// that cannot be confirmed, and the peer's remedy — ask the sender again —
  /// is the cheap side of being wrong.
  Future<bool> _servedSourceStillAuthorized(
    String cid,
    _ServedRecord rec,
  ) async {
    if (rec.roots.isEmpty) return true;
    final authorize = servedSourceAuthorizer;
    if (authorize != null && await authorize(rec.path, rec.roots)) return true;
    devLog(
      () =>
          'xVeil[content]: durable source ${rec.path} is no longer inside a '
          'granted folder — refusing ${cid.substring(0, 12)}',
    );
    return false;
  }

  /// Open the durable source of [cid] — and only if it still IS [cid], and
  /// only if we may still open it at all.
  ///
  /// Every reopen-by-name on the serve path goes through here. See
  /// [_servedSourceStillMatches] for what the content check is worth.
  ///
  /// The AUTHORIZATION half is separate and outlives nothing: a `served:`
  /// record used to survive both the folder being withdrawn from the token and
  /// the token itself being revoked, so an offer made on a bot's behalf kept
  /// reading out of a folder nobody had granted for as long as the peer asked.
  /// A record that names the roots that authorized it is re-checked against
  /// what is granted NOW, every time — never cached, because a revoke that
  /// takes effect on a timer is not a revoke.
  Future<ServeSource?> _openVerifiedServedSource(
    String cid,
    _ServedRecord rec,
  ) async {
    final opener = sourceOpener;
    if (opener == null) return null;
    if (!await _servedSourceStillAuthorized(cid, rec)) return null;
    if (!await _servedSourceStillMatches(cid, rec)) {
      devLog(
        () =>
            'xVeil[content]: durable source ${rec.path} no longer holds '
            '${cid.substring(0, 12)} — refusing to serve it',
      );
      return null;
    }
    return opener(rec.path);
  }

  Future<void> _persistServeManifest(ContentManifest manifest) async {
    try {
      await _storage.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(_contentManifestJson(manifest))),
        name: 'manifest',
      );
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: serve-manifest persist failed '
            '${manifest.contentId.substring(0, 12)}: $e',
      );
    }
  }

  bool _sameServeSource(ServeSource a, ServeSource b) =>
      _contentServing.sameSource(a, b);

  void _retireServeSourceForContent(String cid, ServeSource source) =>
      _contentServing.retireForContent(cid, source);

  /// Persist [bytes] to the blob store (streamed pieces) and advertise. One
  /// source of truth for the in-RAM serve+advertise tail (the bare-content API
  /// and the in-RAM message path); [bytes] is not retained past the store.
  Future<void> _advertise(
    NodeId dst,
    ContentManifest manifest,
    Uint8List bytes,
  ) async {
    try {
      await _storeServedBlob(manifest, bytes);
    } catch (e) {
      devLog(
        () => 'xVeil[content]: serve-store failed for ${manifest.name}: $e',
      );
    }
    await _advertiseStored(dst, manifest);
  }

  /// Offer [bytes] as a bare content transfer to [dst] (no chat message / event
  /// identity): build the manifest, serve it, advertise it. Returns the contentId
  /// (the bytes' self-authenticating address). Used by tests + the recovery
  /// re-ship; user file sends go through [_sendAsContent] (which adds the event).
  Future<String> _publishContent(
    NodeId dst,
    Uint8List bytes,
    String name,
  ) async {
    final manifest = ContentManifest.fromBytes(
      name,
      bytes,
      pieceSize: MessagingService.adaptivePieceSize(bytes.length),
      chunkBytes: MessagingService._contentChunkBytes,
    );
    final contact = await _storage.getContact(dst);
    if (contact?.status == ContactStatus.accepted) {
      await _advertise(dst, manifest, bytes);
    }
    return manifest.contentId;
  }

  ContentManifest _baseContentManifest(ContentManifest manifest) =>
      ContentManifest(
        name: manifest.name,
        size: manifest.size,
        pieceSize: manifest.pieceSize,
        pieceHashes: manifest.pieceHashes,
        contentId: manifest.contentId,
        chunkBytes: manifest.chunkBytes,
      );

  /// Share an already-stored content-addressed blob as a NEW filePost without
  /// loading or duplicating its bytes. The cloud layer uses this path: the
  /// manifest and blob remain keyed by the same cid, while this recipient gets
  /// a fresh message/event identity and the normal consent-gated offer flow.
  Future<bool> _shareStoredContent(NodeId dst, String contentId) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return false;
    }
    if (!await _storage.hasFile(contentId)) return false;
    final persisted = await _loadPersistedManifest(contentId);
    if (persisted == null) return false;
    _mailboxDelivery.noteActivity();
    _warmStreamPeer(dst);

    // Strip any old per-send fields: a cid can be shared repeatedly and each
    // recipient must get a distinct filePost, while the immutable byte
    // manifest remains identical.
    final base = _baseContentManifest(persisted);
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 ${base.name}',
      MessageStatus.sent,
      fileId: contentId,
      fileName: base.name,
      fileSize: base.size,
      thumb: base.thumbB64,
      id: msgId,
      timestamp: _now(),
    );
    _signal();
    await _advertiseStored(
      dst,
      base.withEvent(
        msgId: msgId,
        author: stored.author,
        seq: stored.seq,
        ts: stored.timestamp.millisecondsSinceEpoch,
        thumbB64: base.thumbB64,
      ),
    );
    return true;
  }

  /// Send a VOICE MESSAGE: the Opus clip [bytes] ride the content layer exactly
  /// like a small file (content-addressed, auto-downloaded under the receiver's
  /// cap), named `.opus` so both ends render a voice bubble. The clip's
  /// [durationMs] + [waveform] travel in the SAME `thumb` sidecar image
  /// micro-thumbs use (tagged `vw1:`), so nothing new crosses the wire. Gated to
  /// accepted contacts inside [_sendAsContent].
  Future<void> _sendVoiceContent(
    NodeId dst,
    Uint8List bytes,
    int durationMs,
    List<double> waveform, {
    String? lang,
  }) async {
    _mailboxDelivery.noteActivity(); // user action → mailbox burst window
    _warmStreamPeer(dst);
    // Carry the SENDER's language in the sidecar so the receiver transcribes in
    // the spoken language, not their own locale.
    final sidecar = encodeVoiceSidecar(durationMs, waveform, lang: lang);
    final name = '${_uuid.v4()}$kVoiceFileExt';
    await _sendAsContent(dst, bytes, name, thumbOverride: sidecar);
  }

  /// Send a VIDEO NOTE (round message): the VNOTE1 clip [bytes] ride the
  /// content layer like a small file, named `.vnote` so both ends render the
  /// round bubble. Duration + the first-frame micro-thumb travel in the same
  /// `thumb` sidecar (tagged `vn1:`) — the receiver renders BEFORE/without
  /// downloading. Gated to accepted contacts inside [_sendAsContent].
  Future<void> _sendVideoNoteContent(
    NodeId dst,
    Uint8List bytes,
    int durationMs, {
    String? thumbB64,
  }) async {
    _mailboxDelivery.noteActivity(); // user action → mailbox burst window
    _warmStreamPeer(dst);
    final sidecar = encodeVnoteSidecar(durationMs, thumbB64);
    final name = '${_uuid.v4()}$kVnoteFileExt';
    await _sendAsContent(dst, bytes, name, thumbOverride: sidecar);
  }

  /// Send a STICKER: the image [bytes] ride the content path under `.stkr`
  /// (auto-downloaded under the receiver's cap), with an ordinary image
  /// micro-thumb in the sidecar so the receiver previews it instantly. The
  /// extension makes both ends render it naked (no bubble chrome).
  Future<void> _sendStickerContent(NodeId dst, Uint8List bytes) async {
    _mailboxDelivery.noteActivity();
    _warmStreamPeer(dst);
    final thumb = await _imageThumbMaker(bytes);
    final name = '${_uuid.v4()}$kStickerFileExt';
    await _sendAsContent(dst, bytes, name, thumbOverride: thumb);
  }

  /// Send a shared STICKER PACK: the STKP1 [blob] rides the content path under
  /// `.stkpack` so the receiver gets an install card. A thumb of the first
  /// sticker ([firstThumbB64]) previews it before download.
  Future<void> _sendStickerPackContent(
    NodeId dst,
    Uint8List blob, {
    String? firstThumbB64,
  }) async {
    _mailboxDelivery.noteActivity();
    _warmStreamPeer(dst);
    final name = '${_uuid.v4()}$kStickerPackFileExt';
    await _sendAsContent(dst, blob, name, thumbOverride: firstThumbB64);
  }

  /// Send a LARGE file via the content layer as a first-class filePost EVENT.
  /// The BYTES are content-addressed (stored + served by contentId, de-duped);
  /// the MESSAGE is a per-send event under a fresh [msgId] + the (author,seq) the
  /// log allocates — so a re-send (even of previously-DELETED content) surfaces
  /// as a NEW message (A), while identical bytes are never re-stored/re-fetched.
  Future<void> _sendAsContent(
    NodeId dst,
    Uint8List bytes,
    String name, {
    String? sourcePath,
    String? thumbOverride,
  }) async {
    // Micro-thumb: embedded in the ADVERT (unbound — not in contentId) so the
    // receiver renders a preview BEFORE downloading. [thumbOverride] wins when
    // set (a voice message's waveform+duration sidecar). Otherwise: images from
    // the in-RAM bytes; videos need the SOURCE PATH (the platform grabber
    // decodes from disk — bytes-only callers get no video thumb, deliberately:
    // writing a plaintext temp file just to grab a frame is not worth it). Null
    // for anything undecodable / over the datagram budget.
    String? thumb = thumbOverride;
    if (thumb == null && isImageFileName(name)) {
      thumb = await _imageThumbMaker(bytes);
    } else if (thumb == null && isVideoFileName(name) && sourcePath != null) {
      try {
        thumb = await _videoThumbMaker(sourcePath);
      } catch (e) {
        devLog(() => 'xVeil[content]: video thumb skipped for $name: $e');
      }
    }
    // Hash the file ONCE → the manifest + contentId (the blob key).
    final base = ContentManifest.fromBytes(
      name,
      bytes,
      pieceSize: MessagingService.adaptivePieceSize(bytes.length),
      chunkBytes: MessagingService._contentChunkBytes,
    );
    final cid = base.contentId;
    // Store the blob under its HASH as streamed pieces (uncapped), de-duped: a
    // re-send of identical bytes keeps ONE copy, and a receiver that already
    // holds it skips the re-download. ([_advertise] would also ensure-store, but
    // do it here too so a send to a not-yet-accepted contact still retains the
    // local copy for a later re-ship.)
    try {
      await _storeServedBlob(base, bytes);
    } catch (e) {
      devLog(() => 'xVeil[content]: local store failed for $name: $e');
    }
    // Fresh per-send msgId = a NEW event each send (the (author,seq) event is the
    // identity, NOT the byte-hash → re-send surfaces, even after a delete).
    // fileId = contentId binds the message to its hash-keyed blob.
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: cid,
      fileName: name,
      thumb: thumb,
      id: msgId,
      timestamp: _now(),
    );
    _signal();
    // Advertise carrying THIS send's event identity so the receiver folds a
    // first-class filePost and acks by msgId (not the shared contentId).
    final contact = await _storage.getContact(dst);
    if (contact?.status != ContactStatus.accepted) return;
    await _advertise(
      dst,
      base.withEvent(
        msgId: msgId,
        author: stored.author,
        seq: stored.seq,
        thumbB64: thumb,
      ),
      bytes,
    );
  }

  /// Send a LARGE file by SERVING IT STRAIGHT FROM THE SOURCE — the user's
  /// original file on disk — with no stored or encrypted copy. [read] returns
  /// [length] bytes at [offset] of the source; [close] releases its handle when
  /// serving ends; [size] is the total. The sender already HAS the file, so
  /// keeping a copy would (a) duplicate it — 2× disk for a TB attachment — and
  /// (b) be exactly what overflowed the hidden-volume index on a big send. So we
  /// only HASH the source (one RAM-bounded pass → the manifest), record the
  /// filePost, and register the live source for serving; [_serveChunks] then
  /// reads each requested chunk from it on demand. Same content layer + contentId
  /// as the in-RAM path (so a streamed and an in-RAM send of the same bytes still
  /// share a swarm address). The source is owned by [_serving] and closed on
  /// eviction/dispose — the UI must NOT close it after this returns.
  Future<String?> _sendFileStreamingContent(
    NodeId dst,
    String name,
    int size,
    Future<Uint8List> Function(int offset, int length) read, {
    required Future<void> Function() close,
    String? sourcePath,
    List<String> sourceRoots = const [],
  }) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) {
      await close(); // not serving this peer → release the handle now
      return null;
    }
    _mailboxDelivery.noteActivity(); // user action → mailbox burst window
    // The recipient will pull from us shortly — open our serve pool now, in
    // parallel with the piece hashing below.
    _warmStreamPeer(dst);
    final sw = Stopwatch()..start();
    devLog(
      () =>
          'xVeil[content]: stream-send start "$name" size=$size '
          '-> ${dst.short}',
    );
    // Hash the source piece-by-piece → manifest (contentId + per-piece hashes).
    // Holds at most one piece in RAM; on failure release the handle + surface.
    final ContentManifest base;
    try {
      base = await ContentManifest.fromReader(
        name: name,
        size: size,
        pieceSize: MessagingService.adaptivePieceSize(size),
        chunkBytes: MessagingService._contentChunkBytes,
        readRange: read,
      );
      devLog(
        () =>
            'xVeil[content]: stream-send hashed "$name" '
            'pieces=${base.pieceCount} piece_size=${base.pieceSize} '
            'cid=${base.contentId.substring(0, 12)} '
            'in ${sw.elapsedMilliseconds}ms',
      );
    } catch (e) {
      await close();
      devLog(() => 'xVeil[content]: stream hash failed for $name: $e');
      rethrow;
    }
    final cid = base.contentId;
    // Streamed MEDIA extras — the source isn't in RAM, so read it once
    // (bounded) and reuse the buffer. Reads are serialized by the source's
    // gate.
    // 1. Micro-thumb for the message (images only, optional).
    // 2. A LOCAL piece-store copy for images AND videos under the cap, so
    //    the SENDER's own bubble works (inline preview / in-app playback —
    //    loadFile(cid) → pieces) instead of a dead download affordance: the
    //    no-local-copy rule exists for TB attachments, but sub-cap media
    //    costs pennies and viewing your own send is the whole point. Also
    //    keeps the serve alive even if the source file later moves away.
    String? thumb;
    // Video preview frame: grabbed by PLATFORM code straight from the source
    // path (no size cap — the grabber never reads the file into RAM), so even
    // a multi-GB video gets a bubble thumb. Best-effort: null on platforms
    // without a handler / undecodable containers → the play-icon row.
    if (isVideoFileName(name) && sourcePath != null) {
      try {
        thumb = await _videoThumbMaker(sourcePath);
      } catch (e) {
        devLog(() => 'xVeil[content]: video thumb skipped for $name: $e');
      }
    }
    final mediaCopy =
        (isImageFileName(name) || isVideoFileName(name)) &&
        size <= kThumbSourceReadCapBytes;
    if (mediaCopy) {
      try {
        final mediaBytes = await read(0, size);
        if (isImageFileName(name)) {
          thumb = await _imageThumbMaker(mediaBytes);
        }
        try {
          await _storeServedBlob(base, mediaBytes);
        } catch (e) {
          devLog(
            () =>
                'xVeil[content]: stream-send local copy skipped for '
                '$name: $e',
          );
        }
      } catch (e) {
        devLog(() => 'xVeil[content]: stream-send thumb skipped for $name: $e');
      }
    }
    // Fresh per-send msgId = a NEW filePost event (identity is (author,seq), not
    // the byte-hash → a re-send surfaces even after a delete). fileId = contentId.
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: cid,
      fileName: name,
      fileSize: size,
      thumb: thumb,
      id: msgId,
      timestamp: _now(),
    );
    devLog(
      () =>
          'xVeil[content]: stream-send stored offer '
          '${cid.substring(0, 12)} in ${sw.elapsedMilliseconds}ms',
    );
    _signal();
    final m = base.withEvent(
      msgId: msgId,
      author: stored.author,
      seq: stored.seq,
      thumbB64: thumb,
    );
    final activeExisting = (_activeStreamServes[cid] ?? 0) > 0
        ? _serving[cid]
        : null;
    final activeSource = activeExisting?.source;
    // DURABLE offer: persist the manifest + the source PATH so a reoffer after a
    // restart can re-open the file and re-serve (best-effort; the file must still
    // be at that path). The manifest exceeds the KV value cap → file store.
    if (sourcePath != null && activeSource == null) {
      // The path record and the manifest blob are persisted INDEPENDENTLY: on
      // a bloated store the file-store write dies with IndexFull while the
      // small KV setting still lands. The setting now carries the hashing
      // params too, so a post-restart serve can rebuild the manifest straight
      // from the source file when the mf: blob never made it (one RAM-bounded
      // hashing pass — the same work the original send did).
      try {
        await _storage.putSetting(
          'served:$cid',
          jsonEncode({
            'path': sourcePath,
            'size': size,
            'pieceSize': base.pieceSize,
            'name': name,
            // The grant this offer was made under. Recorded so a later reopen
            // can ask whether it still holds instead of assuming it does.
            if (sourceRoots.isNotEmpty) 'roots': sourceRoots,
          }),
        );
      } catch (e) {
        devLog(
          () =>
              'xVeil[content]: durable-offer path persist failed for $cid: $e',
        );
      }
      try {
        await _storage.storeFile(
          'mf:$cid',
          Uint8List.fromList(utf8.encode(_contentManifestJson(m))),
          name: 'manifest',
        );
      } catch (e) {
        devLog(
          () => 'xVeil[content]: durable-offer persist failed for $cid: $e',
        );
      }
    } else if (sourcePath != null) {
      devLog(
        () =>
            'xVeil[content]: keep active source/path for '
            '${cid.substring(0, 12)} — same-content resend while streaming',
      );
    }
    if (activeSource != null) {
      // We only needed this newly-opened handle to hash/identify the resend. The
      // bytes are identical (same contentId), and an active stream is already
      // using the previous source/path; replacing it mid-flight can close or
      // invalidate the stream's file handle on Android file_picker cache paths.
      await close();
      await _advertiseStored(dst, m, source: activeSource);
    } else {
      // Register the live source + advertise — NO stored copy.
      await _advertiseStored(dst, m, source: (read: read, close: close));
    }
    devLog(
      () =>
          'xVeil[content]: stream-send advertised ${cid.substring(0, 12)} '
          'in ${sw.elapsedMilliseconds}ms',
    );
    return cid;
  }
}
