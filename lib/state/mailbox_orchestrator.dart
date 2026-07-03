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
  })  : _get = getSetting,
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
  MailboxOrchestrator(this._crypto, this._relay, {PoisonedBlobRegistry? poisoned})
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

  /// Fetch our pending blobs, open + verify each, skip (but still ack) ones we
  /// [alreadyHave] (dedup against live delivery), and return the newly-recovered
  /// messages. A blob that fails to open + verify is acked + skipped so one
  /// corrupt/forged blob can't wedge the inbox. Every blob we resolve is acked
  /// so the relay can drop it.
  Future<List<DrainedMessage>> drain({
    required NodeId me,
    required Uint8List authCookie,
    required int ourCertVersion,
    required Future<bool> Function(Uint8List contentId) alreadyHave,
    List<NodeId> knownRelays = const [],
  }) async {
    final blobs =
        await _relay.fetch(me: me, authCookie: authCookie, knownRelays: knownRelays);
    final delivered = <DrainedMessage>[];
    for (final b in blobs) {
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
        // Open failed — unverifiable / corrupt / forged / stale-identity blob.
        // The exception text already carries the native status discriminant
        // (`PeerUnresolved` = sender/recipient identity document unresolvable
        // from the DHT; `Failed` = AEAD / signature / decrypt mismatch). A
        // swallowed open is an invisible "message never arrived" — so LOG it
        // (the single fact needed to tell a reachability gap from a key gap),
        // QUARANTINE the cid (an undecryptable blob never becomes decryptable,
        // and before the registry it was re-fetched + re-failed every drain
        // tick for its whole relay TTL), then ack and move on.
        devLog(() => 'xVeil[drain]: OPEN FAILED contentId=${_shortHex(b.contentId)} '
            'senderHint=${b.senderId.short} — $e');
        _openFailedOnce.add(cidHex); // durable only on a re-sighting (above)
        await _ack(me, b.contentId, authCookie, knownRelays);
        continue;
      }
      delivered.add(DrainedMessage(
        // The CRYPTO-VERIFIED sender, recovered from the blob's sidecar and
        // confirmed by the auth-deliver signature — NOT the relay-supplied wire
        // hint (which is 0 on the anonymous path). This is the trustworthy
        // attribution for the message.
        sender: opened.verifiedSender,
        contentId: b.contentId,
        appId: opened.appId,
        endpointId: opened.endpointId,
        data: opened.data,
      ));
      await _ack(me, b.contentId, authCookie, knownRelays);
    }
    return delivered;
  }

  Future<void> _ack(
    NodeId me,
    Uint8List contentId,
    Uint8List authCookie,
    List<NodeId> knownRelays,
  ) =>
      _relay.ack(
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
