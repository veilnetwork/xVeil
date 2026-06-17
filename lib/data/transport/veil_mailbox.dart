import 'dart:typed_data';

import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../../core/ids.dart';

/// Result of opening a sealed offline-mailbox blob: the verified destination
/// routing target + plaintext.
class OpenedMailboxMessage {
  const OpenedMailboxMessage({
    required this.appId,
    required this.endpointId,
    required this.data,
  });

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

  /// Open + verify a fetched [blob] claimed to be from [sender], decrypting
  /// under our current cert version [ourCertVersion].
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required NodeId sender,
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
    required NodeId sender,
    required int ourCertVersion,
  }) async {
    final r = await _mailbox.open(
      blob: blob,
      sender: sender.bytes,
      ourCertVersion: ourCertVersion,
    );
    return OpenedMailboxMessage(
      appId: r.appId,
      endpointId: r.endpointId,
      data: r.data,
    );
  }
}

/// In-memory fake that round-trips seal↔open WITHOUT any crypto, so the offline
/// orchestration can be unit-tested without a live node. The blob just frames
/// `(appId, endpointId, data)`; `recipient` / `sender` / `ourCertVersion` are
/// ignored (the real adapter binds + verifies them). NEVER use in production.
class LoopbackMailboxCrypto implements VeilMailboxCrypto {
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
    required NodeId sender,
    required int ourCertVersion,
  }) async {
    if (blob.length < 36) {
      throw const FormatException('mailbox blob too short');
    }
    final appId = Uint8List.fromList(blob.sublist(0, 32));
    final endpointId = ByteData.sublistView(blob, 32, 36).getUint32(0);
    final data = Uint8List.fromList(blob.sublist(36));
    return OpenedMailboxMessage(
      appId: appId,
      endpointId: endpointId,
      data: data,
    );
  }
}
