part of 'messaging_core.dart';

/// Server-side content delivery kept separate from the receiver/pull engine.
///
/// This extension owns request validation, bounded datagram piece serving and
/// inbound reliable-stream responses. Configuration and live registries remain
/// fields of [MessagingService], so extraction does not alter lifecycle, wire
/// format or the public API.
extension _MessagingContentServer on MessagingService {
  void _onPieceRequest(NodeId peer, PieceRequestFrame req) {
    final served = _serving[req.contentId];
    if (served == null) {
      devLog(
        () =>
            'xVeil[content]: pieceRequest for UNSERVED '
            '${req.contentId.substring(0, 12)} <- ${peer.short} (ignored)',
      );
      return; // not serving this content
    }
    // Refresh freshness on EVERY request (even one we skip) — it isn't evicted
    // mid-flight, and the live serve loop reads this to know the receiver is
    // still interested (it STOPS when the requests stop — see [_serveChunks]).
    _serving[req.contentId] = (
      manifest: served.manifest,
      source: served.source,
      servedAt: _now(),
    );
    if (_servingNow.contains(req.contentId)) {
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            '— a serve is already in flight, skipping <- ${peer.short}',
      );
      return; // one serve loop per content (single-cursor source)
    }
    final m = served.manifest;
    // gaps: pieceIndex → chunk indices to serve (null ⇒ every chunk of the piece).
    final Map<int, List<int>?> gaps;
    final bm = req.bitmaps;
    if (bm != null && bm.isNotEmpty) {
      gaps = {
        for (final e in bm.entries)
          if (e.key >= 0 && e.key < m.pieceCount)
            e.key: _chunksFromBitmap(m, e.key, e.value),
      };
      final total = gaps.values.fold<int>(0, (a, b) => a + (b?.length ?? 0));
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            'CHUNK-granular ($total chunks over ${gaps.length} pieces) '
            '<- ${peer.short} -> serving',
      );
    } else {
      final indices = req.indices ?? [for (var i = 0; i < m.pieceCount; i++) i];
      gaps = {for (final p in indices) p: null};
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            '(${indices.length}/${m.pieceCount} whole pieces) <- ${peer.short} '
            '-> serving',
      );
    }
    _servingNow.add(req.contentId);
    // The serve runs detached, so its failure has nowhere to be returned TO —
    // and with no line logged on a successful chunk either, a serve that threw
    // on its first read looked exactly like one that delivered every byte:
    // "-> serving" and then silence, whichever happened. Say which.
    final total = gaps.values.fold<int>(
      0,
      (a, b) => a + (b?.length ?? m.chunkCount(0)),
    );
    unawaited(
      _serveChunks(peer, m, served.source, gaps)
          // A serve that never finishes holds [_servingNow] forever, and every
          // later request for this content is answered with "a serve is already
          // in flight, skipping" — so one hung serve stops the transfer for
          // good, while ordinary messages to the same peer keep flowing and
          // hide it. Observed exactly so: "-> serving", then not one chunk, no
          // DONE, no FAILED, and a 240 KB file that never arrived in 180 s.
          //
          // The bound is deliberately generous — it is a stuck-serve release,
          // not a throughput limit — and the receiver re-requests anyway, so
          // the cost of releasing early is one repeated window.
          .timeout(
            MessagingService._serveAbandonTimeout,
            onTimeout: () => throw TimeoutException(
              'serve made no progress',
              MessagingService._serveAbandonTimeout,
            ),
          )
          .then(
            (_) => devLog(
              () =>
                  'xVeil[content]: serve DONE ${req.contentId.substring(0, 12)} '
                  '— $total chunks -> ${peer.short}',
            ),
          )
          .catchError((Object e, StackTrace s) {
            devLog(
              () =>
                  'xVeil[content]: serve FAILED '
                  '${req.contentId.substring(0, 12)} -> ${peer.short} '
                  'after $total chunks queued: $e',
            );
          })
          .whenComplete(() => _servingNow.remove(req.contentId)),
    );
  }

  /// Drop served manifests idle past their TTL, then — if still over the
  /// registry cap — evict the OLDEST until under it. A serve-from-source
  /// entry's [ServeSource.close] is called as it leaves (release the file
  /// handle); a later re-request to an evicted entry simply finds nothing served
  /// and the receiver gives up (a re-send re-opens the source).
  void _evictServing() => _contentServing.evict();

  /// Decode a missing-chunk bitmap into the chunk indices it marks for piece [p].
  List<int> _chunksFromBitmap(ContentManifest m, int p, Uint8List bm) {
    final cc = m.chunkCount(p);
    return [
      for (var c = 0; c < cc; c++)
        if ((c >> 3) < bm.length && (bm[c >> 3] & (1 << (c & 7))) != 0) c,
    ];
  }

  /// Serve [gaps] (pieceIndex → chunk indices, null ⇒ all chunks of the piece)
  /// of content [m] to [peer]. Each chunk's bytes are read either from [source]
  /// (the sender's original file, for a large serve-from-source send) or — when
  /// [source] is null — from the on-disk blob ([readFileRange]) at the derived
  /// offset; the file is never held in RAM. Chunk coordinates come from the
  /// manifest's [ContentManifest.chunkBytes] so they match the receiver.
  Future<void> _serveChunks(
    NodeId peer,
    ContentManifest m,
    ServeSource? source,
    Map<int, List<int>?> gaps,
  ) async {
    // Flatten the requested (piece, chunk) coordinates into one list so we can
    // emit them in bounded batches across pieces, not strictly piece-by-piece.
    final coords = <({int p, int c})>[];
    for (final entry in gaps.entries) {
      final p = entry.key;
      if (p < 0 || p >= m.pieceCount) continue;
      final n = m.chunkCount(p);
      final chunks = entry.value ?? [for (var c = 0; c < n; c++) c];
      for (final c in chunks) {
        if (c >= 0 && c < n) coords.add((p: p, c: c));
      }
    }
    for (var i = 0; i < coords.length; i += _contentServeBatch) {
      // Stop a long serve the receiver has ABANDONED: if it stopped re-requesting
      // (its fetch completed / went stale), our [_serving] freshness goes stale
      // (refreshed on every pieceRequest). Otherwise the sender grinds out a
      // whole big file nobody is fetching (the receiver logs "pieceChunk DROPPED"
      // for every late chunk) — wasted bandwidth + log spam.
      final cur = _serving[m.contentId];
      if (cur == null ||
          _now().difference(cur.servedAt) >
              MessagingService._serveAbandonTimeout) {
        devLog(
          () =>
              'xVeil[content]: serve STOPPED ${m.contentId.substring(0, 12)} '
              'at chunk $i/${coords.length} — receiver no longer requesting',
        );
        return;
      }
      final end = (i + _contentServeBatch < coords.length)
          ? i + _contentServeBatch
          : coords.length;
      // READ the batch sequentially (a serve-from-source RandomAccessFile is a
      // single cursor — concurrent reads would race it; on-disk readFileRange is
      // fine either way), then SEND the batch CONCURRENTLY for throughput — the
      // re-request loop refills anything the TX queue sheds under load.
      final batch = <({int p, int c, Uint8List data})>[];
      for (var j = i; j < end; j++) {
        final p = coords[j].p, c = coords[j].c;
        final cb = m.chunkBytes;
        final plen = m.pieceLength(p);
        final cstart = p * m.pieceSize + c * cb;
        final clen = (c * cb + cb <= plen) ? cb : plen - c * cb;
        Uint8List? data;
        try {
          data = source != null
              ? await source.read(cstart, clen)
              : await _storage.readFileRange(m.contentId, cstart, clen);
        } catch (e) {
          devLog(
            () =>
                'xVeil[content]: serve read failed '
                '${m.contentId.substring(0, 12)} p$p c$c: $e',
          );
        }
        if (data != null) batch.add((p: p, c: c, data: data));
      }
      await Future.wait([
        for (final ch in batch)
          _send(
            peer,
            pieceChunkEnvelope(
              contentId: m.contentId,
              pieceIndex: ch.p,
              chunkIndex: ch.c,
              chunkCount: m.chunkCount(ch.p),
              data: ch.data,
            ).encode(),
          ),
      ]);
      await Future<void>.delayed(
        _contentPacing,
      ); // anti-burst pace between batches
    }
  }

  bool _beginStreamServe(String cid, {int? limit}) {
    final maxActive = (limit ?? _streamRangeParallelism).clamp(
      1,
      MessagingService._maxStreamRangeParallelism,
    );
    return _contentServing.beginStream(cid, maxActive);
  }

  void _endStreamServe(String cid) => _contentServing.endStream(cid);

  /// The ANONYMOUS serve lane. Deliberately not gated on [provenance], and the
  /// reasoning belongs where the next reader will look for it.
  ///
  /// This lane's initiator is derived from an onion cell, so it is
  /// [SenderProvenance.claimed] by construction — not by oversight. Demanding
  /// authentication here would not secure the lane, it would delete it: an
  /// anonymous pull is how a file reaches a peer that is not directly
  /// reachable, which for two NAT'd phones is every time. Provenance has no
  /// answer to give here, so the serve keeps resting on the checks that do
  /// apply — accepted-contact status or a live group grant, plus knowing the
  /// content id at all — and this call states its level rather than leaving the
  /// next reader to assume one was checked.
  void _acceptAnonymousContentStream(
    NodeId peer,
    SenderProvenance provenance,
    ReliableStream stream,
  ) {
    _bulkStreamLog(
      () =>
          'xVeil[content]: stream-accept anon <- ${peer.short} '
          '(${provenance.name})',
    );
    _contentStreams.runServe(stream, () => _serveStream(peer, stream));
  }

  /// The DIRECT serve lane, where the opposite is true: veil reads the
  /// initiator off the authenticated session the `APP_OPEN` arrived on, so an
  /// answer exists and refusing to consult it is the mistake X/V-01 is about.
  ///
  /// Unlike a datagram piece serve — whose bytes go to the NAMED node, so a
  /// spoofer spends our bandwidth but receives nothing — the peer that opened
  /// this stream is holding the other end of it. Whoever we serve here is
  /// whoever gets the file. Both of veil's open paths authenticate today, so
  /// this costs nothing honest; it stops the day one of them stops.
  void _acceptP2PContentStream(
    NodeId peer,
    SenderProvenance provenance,
    ReliableStream stream,
  ) {
    _contentStreams.runServe(stream, () async {
      if (!provenance.isAuthenticated) {
        devLog(
          () =>
              'xVeil[content]: stream-accept p2p DENIED <- ${peer.short} — '
              'the open is unauthenticated (${provenance.name}), so the name '
              'is a claim, not a contact',
        );
        try {
          await stream.close();
        } catch (_) {}
        return;
      }
      if (await _p2pStreamAllowed(peer)) {
        _bulkStreamLog(
          () =>
              'xVeil[content]: stream-accept p2p <- ${peer.short} '
              '(${provenance.name})',
        );
        await _serveStream(peer, stream);
        return;
      }
      devLog(() => 'xVeil[content]: stream-accept p2p DENIED <- ${peer.short}');
      try {
        await stream.close();
      } catch (_) {}
    });
  }

  /// Serve one inbound bulk stream: read the 32-byte contentId, then write the
  /// manifest + the file bytes from our source (live serve-from-source, or a
  /// durable re-open). Closes the stream (EOF) when done / on any failure.
  Future<void> _serveStream(NodeId peer, ReliableStream stream) async {
    ServeSource? durable; // opened just for this serve (closed in finally)
    String? activeCid;
    var failed = false;
    try {
      _bulkStreamLog(
        () => 'xVeil[content]: stream-serve accepted <- ${peer.short}',
      );
      final reqBytes = await MessagingService._readExactly(
        stream,
        MessagingService._streamRequestBytes,
      ).timeout(_streamRequestTimeout, onTimeout: () => null);
      if (reqBytes == null) {
        devLog(
          () =>
              'xVeil[content]: stream-serve EOF/timeout before request '
              '<- ${peer.short}',
        );
        return; // peer hung up before requesting
      }
      final cidBytes = Uint8List.sublistView(reqBytes, 0, 32);
      final cid = MessagingService._hexEncode(cidBytes);
      final requestedOffset = reqBytes.length >= 40
          ? MessagingService._readU64be(Uint8List.sublistView(reqBytes, 32, 40))
          : 0;
      final requestedLength = reqBytes.length >= 48
          ? MessagingService._readU64be(Uint8List.sublistView(reqBytes, 40, 48))
          : 0;
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve request '
            '${cid.substring(0, 12)}'
            '${requestedOffset > 0 ? ' @ $requestedOffset' : ''}'
            '${requestedLength > 0 ? ' +$requestedLength' : ''} '
            '<- ${peer.short}',
      );
      final contact = await _storage.getContact(peer);
      // Serve accepted 1:1 contacts as always; a NON-contact group member is
      // served iff it holds a live membership grant for THIS cid (groups
      // content path — the grant was minted by the authorized signed request).
      if ((contact == null || contact.status != ContactStatus.accepted) &&
          !_groupServeGranted(peer, cid)) {
        devLog(
          () =>
              'xVeil[content]: stream-serve DENIED '
              '${cid.substring(0, 12)} <- ${peer.short} '
              '(not accepted, no group grant)',
        );
        return;
      }
      ContentManifest? manifest;
      ServeSource? source;
      var canReadStoredBlob = false;
      final live = _serving[cid];
      if (live != null) {
        manifest = live.manifest;
        // Prefer a per-stream file handle when we persisted the source path.
        // A repeated send of the same bytes has the same contentId and replaces
        // the shared live source; if this stream borrowed that shared handle, the
        // replacement could close it mid-transfer ("File closed"). A reopened
        // handle is independent and is closed in this method's finally.
        if (sourceOpener != null) {
          final rec = _parseServedRecord(
            await _storage.getSetting('served:$cid'),
          );
          if (rec != null) {
            source = durable = await _openVerifiedServedSource(cid, rec);
          }
        }
        source ??= live.source;
      }
      if (manifest == null) {
        final mfBytes = await _storage.loadFile('mf:$cid');
        if (mfBytes != null) {
          manifest = ContentManifest.fromJson(
            jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
          );
        }
      }
      if (source == null && sourceOpener != null) {
        final rec = _parseServedRecord(
          await _storage.getSetting('served:$cid'),
        );
        if (rec != null) {
          source = durable = await _openVerifiedServedSource(cid, rec);
        }
      }
      // No mf: blob (its persist is the first casualty of a bloated store —
      // IndexFull) but the served: record carries the hashing params: rebuild
      // the manifest from the source file instead of answering UNSERVED.
      if (manifest == null) {
        final rec = _parseServedRecord(
          await _storage.getSetting('served:$cid'),
        );
        if (rec != null) {
          manifest = await _rebuildManifestFromServedRecord(cid, rec);
        }
      }
      if (source == null && manifest != null) {
        canReadStoredBlob = await _storage.hasFile(cid);
      }
      if (manifest == null || (source == null && !canReadStoredBlob)) {
        devLog(
          () =>
              'xVeil[content]: stream-serve UNSERVED '
              '${cid.substring(0, 12)} <- ${peer.short} (close → re-send)',
        );
        return; // close → receiver sees EOF before the manifest
      }
      // A single long stream can wedge inside flow-controlled write() until its
      // write-idle timeout fires. If rangeParallelism is 1, treating that as the
      // per-content serve limit makes every receiver retry get EOF-before-
      // manifest while the old stream is still timing out. When we have an
      // independent per-stream source (durable reopen or stored blob), allow one
      // extra serve so the retry can resume instead of waiting behind the dead
      // writer. Shared live sources keep the configured cap to avoid cursor
      // thrash.
      final independentSource =
          durable != null || (source == null && canReadStoredBlob);
      final serveLimit = independentSource
          ? (_streamRangeParallelism + 4).clamp(
              2,
              MessagingService._maxStreamRangeParallelism,
            )
          : _streamRangeParallelism;
      if (!_beginStreamServe(cid, limit: serveLimit)) {
        devLog(
          () =>
              'xVeil[content]: stream-serve too many active '
              '${cid.substring(0, 12)} <- ${peer.short} '
              '(limit=$serveLimit, closing retry)',
        );
        return;
      }
      activeCid = cid;
      final m = manifest; // promoted non-null (closures need a final)
      final src = source;
      if (src == null) {
        // Warm the manifest for repeated swarm pulls. A null source means the
        // bytes are served from this identity's verified stored blob.
        _serving[cid] = (manifest: m, source: null, servedAt: _now());
        _evictServing();
      }
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve ${cid.substring(0, 12)} '
            '(${m.size}B) -> ${peer.short}',
      );
      if (_disposed) throw StateError('messaging service disposed');
      final mf = Uint8List.fromList(utf8.encode(jsonEncode(m.toJson())));
      await stream
          .write(MessagingService._u32be(mf.length))
          .timeout(MessagingService._streamPayloadWriteTimeout);
      await stream
          .write(mf)
          .timeout(MessagingService._streamPayloadWriteTimeout);
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve manifest sent '
            '${cid.substring(0, 12)} (${mf.length}B) -> ${peer.short}',
      );
      final size = m.size;
      var off = requestedOffset.clamp(0, size).toInt();
      final end = requestedLength > 0
          ? (off + requestedLength).clamp(off, size).toInt()
          : size;
      if (off > 0 || requestedLength > 0) {
        _bulkStreamLog(
          () =>
              'xVeil[content]: stream-serve range '
              '${cid.substring(0, 12)} $off..$end/${size}B -> ${peer.short}',
        );
      }
      final serveSw = Stopwatch()..start();
      var lastServeLogBytes = off;
      var lastServeLogMs = 0;
      while (off < end) {
        if (_disposed) throw StateError('messaging service disposed');
        final n =
            ((end - off) < MessagingService._streamReadChunk
                    ? (end - off)
                    : MessagingService._streamReadChunk)
                .toInt();
        final data = src == null
            ? await _storage
                  .readFileRange(cid, off, n)
                  .timeout(
                    MessagingService._streamSourceReadTimeout,
                    onTimeout: () => throw TimeoutException(
                      'stored blob idle at $off/$size',
                      MessagingService._streamSourceReadTimeout,
                    ),
                  )
            : await src
                  .read(off, n)
                  .timeout(
                    MessagingService._streamSourceReadTimeout,
                    onTimeout: () => throw TimeoutException(
                      'source idle at $off/$size',
                      MessagingService._streamSourceReadTimeout,
                    ),
                  );
        if (data == null || data.isEmpty) {
          throw StateError('source truncated at $off/$size');
        }
        if (_disposed) throw StateError('messaging service disposed');
        await stream
            .write(data)
            .timeout(
              MessagingService._streamPayloadWriteTimeout,
              onTimeout: () => throw TimeoutException(
                'payload write idle at $off/$size',
                MessagingService._streamPayloadWriteTimeout,
              ),
            ); // flow-controlled (back-pressures)
        off += data.length;
        final elapsedMs = serveSw.elapsedMilliseconds;
        if (off == data.length ||
            off >= size ||
            off - lastServeLogBytes >= 1024 * 1024 ||
            elapsedMs - lastServeLogMs >= 2000) {
          _bulkStreamLog(
            () =>
                'xVeil[content]: stream-serve queued '
                '${cid.substring(0, 12)} $off/${size}B -> ${peer.short}',
          );
          lastServeLogBytes = off;
          lastServeLogMs = elapsedMs;
        }
      }
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve complete '
            '${cid.substring(0, 12)} $off/${size}B -> ${peer.short}',
      );
    } catch (e) {
      failed = true;
      devLog(() => 'xVeil[content]: stream-serve failed <- ${peer.short}: $e');
    } finally {
      final cid = activeCid;
      if (cid != null) _endStreamServe(cid);
      if (durable != null) {
        try {
          await durable.close();
        } catch (_) {}
      }
      try {
        if (failed) {
          await stream.abort();
        } else {
          await stream.close();
        }
      } catch (_) {}
    }
  }

  /// Try to download [cid] from [peer] over a RELIABLE stream. Returns true if it
  /// took ownership (runs async to completion / failure); false if streams aren't
  /// available so the caller falls back to the datagram path. The bytes land in
  /// [sink] (unencrypted-to-file) or the Storage port (encrypted tier / in-volume)
  /// with per-piece verification + progress. Works WITHOUT a live offer handle —
  /// the manifest arrives on the stream, so no reoffer dance.
}
