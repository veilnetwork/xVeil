import 'dart:typed_data';

import '../core/ids.dart';
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
  MailboxOrchestrator(this._crypto, this._relay);

  final VeilMailboxCrypto _crypto;
  final VeilMailboxRelay _relay;

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
      if (await alreadyHave(b.contentId)) {
        await _ack(me, b.contentId, authCookie);
        continue;
      }
      OpenedMailboxMessage opened;
      try {
        opened = await _crypto.open(
          blob: b.blob,
          ourCertVersion: ourCertVersion,
        );
      } catch (_) {
        // Unverifiable / corrupt / forged blob — ack so it doesn't wedge the
        // inbox, and move on.
        await _ack(me, b.contentId, authCookie);
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
      await _ack(me, b.contentId, authCookie);
    }
    return delivered;
  }

  Future<void> _ack(NodeId me, Uint8List contentId, Uint8List authCookie) =>
      _relay.ack(me: me, contentId: contentId, authCookie: authCookie);
}
