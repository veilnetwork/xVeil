import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/transport/veil_mailbox.dart';

/// A message recovered by [MailboxOrchestrator.drain]: the verified sender +
/// routing target + plaintext, plus the content id for storage-side dedup.
class DrainedMessage {
  const DrainedMessage({
    required this.sender,
    required this.contentId,
    required this.appId,
    required this.endpointId,
    required this.data,
  });

  /// Verified sender — recovered from the blob's sidecar and confirmed by the
  /// auth-deliver signature inside `open` (NOT the relay-supplied wire hint).
  /// Safe to attribute the message to this identity.
  final NodeId sender;

  /// Content id (= message uuid) of the delivered blob.
  final Uint8List contentId;

  /// Verified destination app id.
  final Uint8List appId;

  /// Verified destination endpoint id.
  final int endpointId;

  /// Verified plaintext.
  final Uint8List data;
}

/// Durable quarantine for mailbox blobs whose `open` failed PERMANENTLY
/// (AEAD/signature mismatch — e.g. sealed against a stale identity by an old
/// build). Decryption is deterministic, so such a blob will NEVER open; without
/// this registry the drain re-fetched + re-failed the same blob every tick for
/// the blob's whole 7-day relay TTL, and — because it looked like fresh mail —
/// kept the drain cadence at its fastest the entire time.
///
/// Persisted as one JSON list of cid-hex under a settings key (the storage
/// layer's no-change dedup makes re-persists free), FIFO-capped so a flood of
/// junk deposits can't grow the container.
class PoisonedBlobRegistry {
  PoisonedBlobRegistry({
    required Future<String?> Function(String key) getSetting,
    required Future<void> Function(String key, String value) putSetting,
  }) : _get = getSetting,
       _put = putSetting;

  static const String _key = 'mailbox.poisoned.v1';
  static const int _cap = 64;

  final Future<String?> Function(String) _get;
  final Future<void> Function(String, String) _put;
  List<String>? _cache; // cid hex, FIFO order (oldest first)

  Future<List<String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <String>[];
    try {
      final raw = await _get(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is String) out.add(e);
          }
        }
      }
    } catch (_) {
      // Unreadable registry → start empty (failed opens re-quarantine).
    }
    return _cache = out;
  }

  Future<bool> contains(Uint8List contentId) async =>
      (await _load()).contains(_hex(contentId));

  Future<void> add(Uint8List contentId) async {
    final list = await _load();
    final hex = _hex(contentId);
    if (list.contains(hex)) return;
    list.add(hex);
    while (list.length > _cap) {
      list.removeAt(0);
    }
    try {
      await _put(_key, jsonEncode(list));
    } catch (_) {
      // Best-effort: the in-RAM cache still shields this session.
    }
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// Offline-delivery orchestration: seal a message for an offline peer and stash
/// it at a relay, and on reconnect drain our mailbox (fetch → open → dedup →
/// ack), returning the recovered messages for the caller to store + signal.
///
/// DORMANT: nothing invokes this yet. The live triggers (un-acked + peer offline
/// → [stash]; node-connect → [drain]) and the relay-specific inputs (`authCookie`
/// from our rendezvous registration, the recipient's mailbox addressing) are the
/// relay-infrastructure decision; they are passed in so this state machine can be
/// built + tested ([LoopbackMailboxCrypto] + [InMemoryMailboxRelay]) ahead of it.
class MailboxOrchestrator {
  // Named public API keeps `poisoned`; a private initializing formal would
  // expose `_poisoned` to callers, which Dart forbids across libraries.
  MailboxOrchestrator(
    this._crypto,
    this._relay, {
    PoisonedBlobRegistry? poisoned,
  })
    // ignore: prefer_initializing_formals
    : _poisoned = poisoned;

  final VeilMailboxCrypto _crypto;
  final VeilMailboxRelay _relay;
  final PoisonedBlobRegistry? _poisoned;

  /// cids whose open failed THIS session (in-RAM tier of the quarantine). The
  /// durable registry is written only when a failed cid is sighted AGAIN after
  /// its ack (= an ack-less relay will re-serve it until TTL — worth one padded
  /// commit to survive relaunches). A one-shot junk deposit that the ack
  /// removes costs NO container write — a live producer of fresh junk blobs
  /// must not be able to grow the container one commit per blob.
  final Set<String> _openFailedOnce = {};

  /// Per-cid count of TRANSIENT open failures (the node's IPC didn't answer —
  /// "timeout waiting for mailbox_open reply" — which says nothing about the
  /// blob itself). Such a blob is retried on later drains WITHOUT acking, so
  /// the relay keeps its copy; only after [_transientOpenCap] consecutive
  /// timeouts is it treated as permanently poisoned. In-RAM only (a restart
  /// retries from zero — correct for a node-side transient). Bounded so junk
  /// cannot grow it.
  final Map<String, int> _transientOpenFails = {};
  static const _transientOpenCap = 6;
  static const _transientOpenFailsMax = 512;

  /// Seal [data] for offline [recipient]'s ([appId], [endpointId]) and deposit
  /// it at the relay under [contentId] (the message uuid, so the recipient can
  /// dedup against a later live delivery of the same message).
  Future<void> stash({
    required NodeId me,
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
    required Uint8List contentId,
  }) async {
    final blob = await _crypto.seal(
      recipient: recipient,
      appId: appId,
      endpointId: endpointId,
      data: data,
    );
    await _relay.put(
      receiver: recipient,
      contentId: contentId,
      sender: me,
      blob: blob,
    );
  }

  /// Cap on ack-then-refetch rounds within ONE drain (see [drain]). 16 rounds
  /// x ~4 KB/blob clears a decent backlog per drain while bounding the onion
  /// round-trips; the rest continues next tick.
  static const int _maxDrainRounds = 16;

  /// When a fetch re-serves only blobs already handled THIS drain (their ack
  /// removal is still in flight), wait this long before re-fetching so the
  /// relay has a chance to apply the removal and serve the NEXT oldest blob.
  /// The ack is an onion send: the relay applies the removal ~one round-trip
  /// AFTER we send it (~1-2 s observed on the prod relays), so the poll has to
  /// span that — a sub-second budget exited before the removal landed, which
  /// bounced the backlog to the next (3 s-interval) tick, the ~1-blob-per-tick
  /// recovery. 700 ms × the retry cap below ≈ 4 s covers the observed window.
  static const Duration _ackSettleDelay = Duration(milliseconds: 700);

  /// Bound on consecutive ack-settle waits before giving up the drain — so a
  /// relay that never removes (e.g. a pre-ack-endpoint build) cannot spin the
  /// loop. ~4 s total (× [_ackSettleDelay]) covers a prod relay's ack-removal
  /// latency so the whole backlog clears in ONE drain; a relay that still
  /// re-serves after that drops the remainder to the next tick (bounded, no
  /// spin). Only spent while actively draining — an empty relay breaks first.
  static const int _maxAckSettleRetries = 6;

  /// Fetch our pending blobs, open + verify each, skip (but still ack) ones we
  /// [alreadyHave] (dedup against live delivery), and return the newly-recovered
  /// messages. A blob that fails to open + verify is acked + skipped so one
  /// corrupt/forged blob can't wedge the inbox. Every blob we resolve is acked
  /// so the relay can drop it.
  ///
  /// Drains until EMPTY (bounded): the relay's FETCH reply must fit one signed
  /// AuthDeliver (~6 KB), so a backlog is served roughly ONE ~4 KB blob per
  /// fetch — the protocol's documented contract is "the receiver re-fetches
  /// after acking to drain more", which this loop implements. Without it a
  /// receiver returning from days offline got its queued mail at one message
  /// per drain TICK, and an old junk-blob backlog surfaced one "fresh"
  /// undecryptable cid per drain, forever — indistinguishable from a live
  /// junk producer. A round that re-serves only already-handled blobs is an
  /// ack-in-flight window, not an empty relay: the loop waits [_ackSettleDelay]
  /// and re-fetches (bounded by [_maxAckSettleRetries]) so the whole backlog
  /// clears in ONE drain, instead of one blob per interval-delayed tick. It
  /// stops only when a fetch returns NOTHING (relays truly empty).
  Future<List<DrainedMessage>> drain({
    required NodeId me,
    required Uint8List authCookie,
    required int ourCertVersion,
    required Future<bool> Function(Uint8List contentId) alreadyHave,
    List<NodeId> knownRelays = const [],
    bool Function()? shouldContinue,
    /// Invoked the moment a blob is opened and verified, BEFORE the loop goes
    /// looking for more. The returned list still carries everything, so a
    /// caller that only wants the batch can ignore this.
    void Function(DrainedMessage message)? onMessage,
  }) async {
    final delivered = <DrainedMessage>[];
    final seenThisDrain = <String>{};
    // A relay's FETCH reply fits only ~1 blob (a ~4 KB blob overflows the
    // one-AuthDeliver budget), so a backlog drains one blob per round. The ACK
    // that removes a handled blob is a fire-and-forget onion send: for a short
    // window AFTER we ack, the relay STILL serves that same oldest blob, so the
    // next fetch returns only cids we've already handled this drain (`fresh`
    // empty) even though MORE blobs are queued behind it. Ending the drain there
    // deferred the rest of the backlog to the next (interval-delayed) tick — the
    // observed ~1-blob-per-7s recovery after churn. Distinguish the two cases:
    //   * `blobs` empty        → relays are truly drained; stop.
    //   * `blobs` non-empty but all-seen → ack removal hasn't landed yet; wait a
    //     beat for it and re-fetch so the NEXT oldest surfaces THIS drain.
    var ackSettleRetries = 0;
    for (var round = 0; round < _maxDrainRounds; round++) {
      if (shouldContinue?.call() == false) break;
      final blobs = await _relay.fetch(
        me: me,
        authCookie: authCookie,
        knownRelays: knownRelays,
      );
      // A call may have started while the native FETCH was in flight. Leave
      // the returned blobs unacked at the relay and stop before decrypt/ack;
      // the first post-call drain will recover them normally.
      if (shouldContinue?.call() == false) break;
      if (blobs.isEmpty) break; // relays truly empty — done
      final fresh = blobs
          .where((b) => seenThisDrain.add(_cidHex(b.contentId)))
          .toList();
      if (fresh.isEmpty) {
        // Relays re-serving only blobs we've handled — their ack removal is
        // still in flight. Wait briefly and retry rather than deferring the
        // backlog to the next tick. Bounded so a relay that never removes
        // (pre-ack build) can't spin the loop: give up after a few settles.
        if (ackSettleRetries++ >= _maxAckSettleRetries) break;
        await Future<void>.delayed(_ackSettleDelay);
        continue;
      }
      ackSettleRetries = 0; // progress made — reset the settle budget
      await _drainRound(
        fresh,
        me: me,
        authCookie: authCookie,
        ourCertVersion: ourCertVersion,
        alreadyHave: alreadyHave,
        knownRelays: knownRelays,
        delivered: delivered,
        shouldContinue: shouldContinue,
        onMessage: onMessage,
      );
    }
    return delivered;
  }

  Future<void> _drainRound(
    List<StoredMailboxBlob> blobs, {
    required NodeId me,
    required Uint8List authCookie,
    required int ourCertVersion,
    required Future<bool> Function(Uint8List contentId) alreadyHave,
    required List<NodeId> knownRelays,
    required List<DrainedMessage> delivered,
    bool Function()? shouldContinue,
    void Function(DrainedMessage message)? onMessage,
  }) async {
    for (final b in blobs) {
      if (shouldContinue?.call() == false) return;
      // Quarantined: this cid already failed open PERMANENTLY (decryption is
      // deterministic). Skip the decrypt — but keep acking so a relay that
      // supports the ack endpoint finally drops it (replicas that missed an
      // earlier ack included). A re-sighting after the in-RAM tier means the
      // ack did NOT stick (pre-ack relay) — promote to the durable registry so
      // the skip survives a relaunch.
      final cidHex = _cidHex(b.contentId);
      if (_openFailedOnce.contains(cidHex)) {
        await _poisoned?.add(b.contentId);
        await _ack(me, b.contentId, authCookie, knownRelays);
        continue;
      }
      if (await (_poisoned?.contains(b.contentId) ?? Future.value(false))) {
        await _ack(me, b.contentId, authCookie, knownRelays);
        continue;
      }
      if (await alreadyHave(b.contentId)) {
        await _ack(me, b.contentId, authCookie, knownRelays);
        continue;
      }
      OpenedMailboxMessage opened;
      try {
        opened = await _crypto.open(
          blob: b.blob,
          ourCertVersion: ourCertVersion,
        );
      } catch (e) {
        // TRANSIENT failure first: an IPC timeout ("timeout waiting for
        // mailbox_open reply" — the node was busy/starting and simply didn't
        // answer) says NOTHING about the blob. Quarantining + acking here
        // DESTROYS a legitimate message: the ack drops the relay's only copy,
        // observed as "blob fetched+ACKed yet the message never surfaced".
        // Skip WITHOUT acking so the relay keeps it and a later drain retries;
        // a bounded per-cid counter still terminates a blob whose opens time
        // out forever.
        if ('$e'.contains('timeout')) {
          final n = (_transientOpenFails[cidHex] ?? 0) + 1;
          if (n < _transientOpenCap) {
            if (_transientOpenFails.length >= _transientOpenFailsMax) {
              _transientOpenFails.remove(_transientOpenFails.keys.first);
            }
            _transientOpenFails[cidHex] = n;
            devLog(
              () =>
                  'xVeil[drain]: open TIMED OUT contentId=${_shortHex(b.contentId)} '
                  '(attempt $n/$_transientOpenCap) — NOT acked, will retry: $e',
            );
            continue;
          }
          // Cap reached — fall through to the permanent path below.
        }
        // Open failed PERMANENTLY — unverifiable / corrupt / forged /
        // stale-identity blob. The exception text carries the native status
        // discriminant (`PeerUnresolved` = sender/recipient identity document
        // unresolvable; `Failed` = AEAD / signature / decrypt mismatch;
        // decryption is deterministic, so retrying cannot help). A swallowed
        // open is an invisible "message never arrived" — so LOG it, QUARANTINE
        // the cid (before the registry it was re-fetched + re-failed every
        // drain tick for its whole relay TTL), then ack and move on.
        //
        // Quarantine DURABLY at once (not lazily on a same-session
        // re-sighting): a relay that never applies our ack re-serves the blob
        // forever, and each failed open costs the node's full cert-resolve
        // timeout (~20 s observed live). With the lazy promote every app
        // RESTART re-paid that per junk blob before the in-RAM tier saw a
        // second sighting — 2 junk blobs alone held a fresh call `answer`
        // behind ~40 s of dead opens, past the caller's dial window. The
        // registry's FIFO cap already bounds what a live junk producer can
        // make us persist.
        devLog(
          () =>
              'xVeil[drain]: OPEN FAILED contentId=${_shortHex(b.contentId)} '
              'senderHint=${b.senderId.short} — $e',
        );
        _openFailedOnce.add(cidHex);
        await _poisoned?.add(b.contentId);
        await _ack(me, b.contentId, authCookie, knownRelays);
        continue;
      }
      _transientOpenFails.remove(cidHex); // opened fine — forget old timeouts
      final message = DrainedMessage(
        // The CRYPTO-VERIFIED sender, recovered from the blob's sidecar and
        // confirmed by the auth-deliver signature — NOT the relay-supplied wire
        // hint (which is 0 on the anonymous path). This is the trustworthy
        // attribution for the message.
        sender: opened.verifiedSender,
        contentId: b.contentId,
        appId: opened.appId,
        endpointId: opened.endpointId,
        data: opened.data,
      );
      delivered.add(message);
      // Hand it up NOW, not when the loop ends. The rounds after this one exist
      // to clear a BACKLOG: they re-fetch, find the relay still serving the blob
      // whose ack is in flight, and wait [_ackSettleDelay] for the removal to
      // land — up to [_maxAckSettleRetries] times. That is correct work, but it
      // is about messages we do NOT have yet, and batching the return until it
      // finished made every message wait out the search for its successors.
      // Measured on the stand: a drain that carried one message took ~6.8s while
      // the fetch that produced it took ~0.5s.
      onMessage?.call(message);
      await _ack(me, b.contentId, authCookie, knownRelays);
    }
  }

  Future<void> _ack(
    NodeId me,
    Uint8List contentId,
    Uint8List authCookie,
    List<NodeId> knownRelays,
  ) => _relay.ack(
    me: me,
    contentId: contentId,
    authCookie: authCookie,
    knownRelays: knownRelays,
  );
}

/// Full hex of a content id — the in-RAM quarantine key.
String _cidHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Compact hex of a content id's first bytes — enough to correlate a failed
/// open with its `fetched N blob(s)` line in the drain log without dumping the
/// whole id.
String _shortHex(Uint8List bytes) {
  final n = bytes.length < 6 ? bytes.length : 6;
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
