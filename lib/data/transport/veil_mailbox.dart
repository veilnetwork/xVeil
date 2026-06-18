import 'dart:typed_data';

import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../../core/ids.dart';

/// Result of opening a sealed offline-mailbox blob: the verified sender +
/// destination routing target + plaintext.
class OpenedMailboxMessage {
  const OpenedMailboxMessage({
    required this.verifiedSender,
    required this.appId,
    required this.endpointId,
    required this.data,
  });

  /// Verified sender — recovered from the blob's sidecar and confirmed by the
  /// auth-deliver signature (NOT the relay-supplied wire hint). This is the
  /// trustworthy attribution source for an offline-delivered message.
  final NodeId verifiedSender;

  /// Verified destination app id (32 bytes).
  final Uint8List appId;

  /// Verified destination endpoint id.
  final int endpointId;

  /// Verified plaintext.
  final Uint8List data;
}

/// Port over the node's offline-mailbox E2E crypto: seal a message into a blob,
/// and open + verify a fetched blob.
///
/// This is the CRYPTO only. The relay transport (put / fetch / ack a blob at a
/// mailbox relay) and the orchestration that decides WHEN to fall back to the
/// mailbox (un-acked + peer offline → seal + put; on reconnect → fetch → open →
/// deliver → ack, dedup by contentId) are a separate, still-to-wire layer —
/// gated on the relay-infrastructure decision + a live end-to-end validation of
/// this seal/open round-trip. A loopback fake ([LoopbackMailboxCrypto]) lets
/// that orchestration be built + tested before the live path exists.
abstract interface class VeilMailboxCrypto {
  /// Seal [data] for [recipient]'s ([appId], [endpointId]) into a mailbox blob
  /// (the node signs an auth-deliver, resolves the recipient's ML-KEM cert over
  /// the DHT, and fan-out-encrypts). Returns the blob to `put` at a relay.
  Future<Uint8List> seal({
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
  });

  /// Open + verify a fetched [blob], decrypting under our current cert version
  /// [ourCertVersion]. The sender is RECOVERED from the blob's sidecar (the
  /// anonymous deposit carries no usable wire sender) and surfaced, crypto-
  /// verified, as [OpenedMailboxMessage.verifiedSender].
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  });
}

/// Production adapter over `veil_flutter`'s [veil.VeilMailbox] (obtained from a
/// running node's `VeilClient.mailbox`).
class VeilFlutterMailboxCrypto implements VeilMailboxCrypto {
  VeilFlutterMailboxCrypto(this._mailbox);

  final veil.VeilMailbox _mailbox;

  @override
  Future<Uint8List> seal({
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
  }) {
    return _mailbox.seal(
      recipient: recipient.bytes,
      appId: appId,
      endpointId: endpointId,
      data: data,
    );
  }

  @override
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  }) async {
    final r = await _mailbox.open(
      blob: blob,
      ourCertVersion: ourCertVersion,
    );
    return OpenedMailboxMessage(
      verifiedSender: NodeId(r.senderNodeId),
      appId: r.appId,
      endpointId: r.endpointId,
      data: r.data,
    );
  }
}

/// In-memory fake that round-trips seal↔open WITHOUT any crypto, so the offline
/// orchestration can be unit-tested without a live node. The blob frames
/// `(sender, appId, endpointId, data)` — [seal] has no sender input (the real
/// node binds its own identity), so the sender to round-trip is taken from
/// [senderForOpen] (default all-zero). `recipient` / `ourCertVersion` are ignored
/// (the real adapter binds + verifies them). NEVER use in production.
class LoopbackMailboxCrypto implements VeilMailboxCrypto {
  // ignore: prefer_initializing_formals
  LoopbackMailboxCrypto({NodeId? senderForOpen}) : _senderForOpen = senderForOpen;

  /// The verified-sender stand-in [open] reports — lets a unit test exercise the
  /// orchestrator's attribution path without real crypto. Null ⇒ all-zero.
  final NodeId? _senderForOpen;

  @override
  Future<Uint8List> seal({
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
  }) async {
    if (appId.length != 32) {
      throw ArgumentError('appId must be 32 bytes, got ${appId.length}');
    }
    final out = BytesBuilder();
    out.add(appId);
    final ep = ByteData(4)..setUint32(0, endpointId);
    out.add(ep.buffer.asUint8List());
    out.add(data);
    return out.toBytes();
  }

  @override
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  }) async {
    if (blob.length < 36) {
      throw const FormatException('mailbox blob too short');
    }
    final appId = Uint8List.fromList(blob.sublist(0, 32));
    final endpointId = ByteData.sublistView(blob, 32, 36).getUint32(0);
    final data = Uint8List.fromList(blob.sublist(36));
    return OpenedMailboxMessage(
      verifiedSender: _senderForOpen ?? NodeId(Uint8List(32)),
      appId: appId,
      endpointId: endpointId,
      data: data,
    );
  }
}

/// A blob fetched from a mailbox relay: who sent it, its content id (for dedup +
/// ack), and the sealed bytes.
class StoredMailboxBlob {
  const StoredMailboxBlob({
    required this.senderId,
    required this.contentId,
    required this.blob,
  });

  /// Relay-supplied sender node_id hint. ⚠️ UNTRUSTED + relay-overridable: it is
  /// `0` for an anonymous network deposit. NOT used for attribution — `open`
  /// recovers the real sender from the blob's sidecar and returns it crypto-
  /// verified ([OpenedMailboxMessage.verifiedSender]). Kept only for the local
  /// IPC relay path / diagnostics; never attribute a message from this hint.
  final NodeId senderId;

  /// 32-byte content id — the message uuid, for dedup against live delivery.
  final Uint8List contentId;

  /// The sealed blob to `open`.
  final Uint8List blob;
}

/// Port over the offline-mailbox RELAY transport: deposit a sealed blob for an
/// offline receiver, fetch our pending blobs, and ack them.
///
/// The `authCookie` + the receiver's mailbox addressing are part of the
/// rendezvous-registration layer (the relay-infrastructure decision — see the
/// offline-delivery design); the orchestration takes them as inputs so its
/// logic can be built + tested ([InMemoryMailboxRelay]) ahead of that decision.
abstract interface class VeilMailboxRelay {
  /// Deposit [blob] (content id [contentId]) for offline [receiver], from us.
  Future<void> put({
    required NodeId receiver,
    required Uint8List contentId,
    required NodeId sender,
    required Uint8List blob,
  });

  /// Fetch all blobs pending for us ([me]), authenticated by [authCookie].
  Future<List<StoredMailboxBlob>> fetch({
    required NodeId me,
    required Uint8List authCookie,
  });

  /// Acknowledge (and let the relay drop) the blob [contentId] for [me].
  Future<void> ack({
    required NodeId me,
    required Uint8List contentId,
    required Uint8List authCookie,
  });
}

/// Production adapter over `veil_flutter`'s mailbox put/fetch/ack.
class VeilFlutterMailboxRelay implements VeilMailboxRelay {
  VeilFlutterMailboxRelay(this._mailbox);

  final veil.VeilMailbox _mailbox;

  @override
  Future<void> put({
    required NodeId receiver,
    required Uint8List contentId,
    required NodeId sender,
    required Uint8List blob,
  }) async {
    await _mailbox.put(
      receiverId: receiver.bytes,
      contentId: contentId,
      senderId: sender.bytes,
      blob: blob,
    );
  }

  @override
  Future<List<StoredMailboxBlob>> fetch({
    required NodeId me,
    required Uint8List authCookie,
  }) async {
    final raw = await _mailbox.fetch(receiverId: me.bytes, authCookie: authCookie);
    return raw
        .map((b) => StoredMailboxBlob(
              senderId: NodeId(b.senderId),
              contentId: b.contentId,
              blob: b.data,
            ))
        .toList();
  }

  @override
  Future<void> ack({
    required NodeId me,
    required Uint8List contentId,
    required Uint8List authCookie,
  }) async {
    await _mailbox.ack(
      receiverId: me.bytes,
      contentId: contentId,
      authCookie: authCookie,
    );
  }
}

/// In-memory relay fake for testing the orchestration without a real relay.
/// Keyed by receiver hex; `authCookie` is ignored (the real relay verifies it).
class InMemoryMailboxRelay implements VeilMailboxRelay {
  final Map<String, List<StoredMailboxBlob>> _store = {};

  @override
  Future<void> put({
    required NodeId receiver,
    required Uint8List contentId,
    required NodeId sender,
    required Uint8List blob,
  }) async {
    (_store[receiver.hex] ??= []).add(StoredMailboxBlob(
      senderId: sender,
      contentId: contentId,
      blob: blob,
    ));
  }

  @override
  Future<List<StoredMailboxBlob>> fetch({
    required NodeId me,
    required Uint8List authCookie,
  }) async =>
      List.unmodifiable(_store[me.hex] ?? const []);

  @override
  Future<void> ack({
    required NodeId me,
    required Uint8List contentId,
    required Uint8List authCookie,
  }) async {
    _store[me.hex]?.removeWhere(
      (b) => _bytesEqual(b.contentId, contentId),
    );
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
