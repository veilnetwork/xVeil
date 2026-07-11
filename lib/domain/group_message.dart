// Group message-log entry (groups epic, phase 0, brick 3): a per-author,
// signed message in a group. Mirrors the 1:1 event-log shape (author + own
// monotonic seq + prev-hash chain) but many authors write into ONE group log;
// each entry is validated locally (author is a non-muted member at its
// policy version, signature ok) before it is shown — same discipline as the
// control-log.

import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';

class GroupMessage {
  GroupMessage({
    required this.groupId,
    required this.author,
    required this.seq,
    required this.prevHash,
    required this.body,
    required this.policyVersion,
    required this.createdAtMs,
    required this.signature,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId groupId;
  final NodeId author;
  final int seq; // this author's monotonic message seq
  final String prevHash; // hex of the author's previous message hash, or ''
  final String body;
  final int policyVersion; // the policy version the author wrote against
  final int createdAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey; // bound via node_id == BLAKE3(pk), not signed

  /// The bytes the author signs — fixed field order, no signature/pubKey.
  Uint8List canonicalBytes() {
    final map = {
      'gid': groupId.hex,
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'body': body,
      'pv': policyVersion,
      'ts': createdAtMs,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  GroupMessage withSignature(Uint8List sig, Uint8List pubKey) => GroupMessage(
        groupId: groupId,
        author: author,
        seq: seq,
        prevHash: prevHash,
        body: body,
        policyVersion: policyVersion,
        createdAtMs: createdAtMs,
        signature: sig,
        authorPubKey: pubKey,
      );

  Map<String, dynamic> toJson() => {
        'gid': groupId.hex,
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'body': body,
        'pv': policyVersion,
        'ts': createdAtMs,
        'sig': base64Encode(signature),
        if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
      };

  static GroupMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final gid = j['gid'], author = j['author'], seq = j['seq'];
    final prev = j['prev'], body = j['body'], pv = j['pv'], ts = j['ts'];
    final sig = j['sig'];
    if (gid is! String ||
        author is! String ||
        seq is! int ||
        prev is! String ||
        body is! String ||
        pv is! int ||
        ts is! int ||
        sig is! String ||
        seq < 0) {
      return null;
    }
    try {
      return GroupMessage(
        groupId: NodeId.fromHex(gid),
        author: NodeId.fromHex(author),
        seq: seq,
        prevHash: prev,
        body: body,
        policyVersion: pv,
        createdAtMs: ts,
        signature: Uint8List.fromList(base64Decode(sig)),
        authorPubKey: j['apk'] is String
            ? Uint8List.fromList(base64Decode(j['apk'] as String))
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}
