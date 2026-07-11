// Group reaction log (groups epic, phase 1): a per-author, signed reaction on a
// message. Like the message log, many authors write into ONE reaction log; each
// is validated (author is a member, signature ok) before it counts. A reaction
// targets a message by its stable ref "<authorHex>:<seq>". An EMPTY emoji
// removes this author's reaction on that message (toggle) — the LATEST reaction
// per (author, target) wins, folded deterministically so every device agrees.

import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';

class GroupReaction {
  GroupReaction({
    required this.groupId,
    required this.author,
    required this.seq,
    required this.target,
    required this.emoji,
    required this.createdAtMs,
    required this.signature,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId groupId;
  final NodeId author;
  final int seq; // this author's monotonic reaction seq
  final String target; // "<authorHex>:<seq>" of the reacted message
  final String emoji; // '' = remove this author's reaction on [target]
  final int createdAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey; // bound via node_id == BLAKE3(pk)

  /// The bytes the author signs — fixed field order, no signature/pubKey.
  Uint8List canonicalBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'gid': groupId.hex,
        'author': author.hex,
        'seq': seq,
        'tgt': target,
        'emoji': emoji,
        'ts': createdAtMs,
      })));

  GroupReaction withSignature(Uint8List sig, Uint8List pubKey) => GroupReaction(
        groupId: groupId,
        author: author,
        seq: seq,
        target: target,
        emoji: emoji,
        createdAtMs: createdAtMs,
        signature: sig,
        authorPubKey: pubKey,
      );

  Map<String, dynamic> toJson() => {
        'gid': groupId.hex,
        'author': author.hex,
        'seq': seq,
        'tgt': target,
        'emoji': emoji,
        'ts': createdAtMs,
        'sig': base64Encode(signature),
        if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
      };

  static GroupReaction? fromJson(Object? j) {
    if (j is! Map) return null;
    final gid = j['gid'], author = j['author'], seq = j['seq'];
    final tgt = j['tgt'], emoji = j['emoji'], ts = j['ts'], sig = j['sig'];
    if (gid is! String ||
        author is! String ||
        seq is! int ||
        tgt is! String ||
        emoji is! String ||
        ts is! int ||
        sig is! String ||
        seq < 0) {
      return null;
    }
    try {
      return GroupReaction(
        groupId: NodeId.fromHex(gid),
        author: NodeId.fromHex(author),
        seq: seq,
        target: tgt,
        emoji: emoji,
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

/// The reactions on one message: emoji -> the reactors (deduped node ids).
typedef MessageReactions = Map<String, List<NodeId>>;

/// Fold a reaction log into `target -> emoji -> reactors`. Deterministic: for
/// each (author, target) the LATEST reaction wins (by createdAtMs, then
/// author.hex, then seq — the same tuple the message log uses), and a winning
/// EMPTY emoji means that author has no reaction. [verify] gates each entry's
/// signature so a forged reaction never counts.
Map<String, MessageReactions> foldGroupReactions(
  Iterable<GroupReaction> reactions,
  bool Function(GroupReaction) verify,
) {
  // Latest reaction per (author, target).
  final latest = <String, GroupReaction>{};
  for (final r in reactions) {
    if (!verify(r)) continue;
    final key = '${r.author.hex}|${r.target}';
    final cur = latest[key];
    if (cur == null || _isNewer(r, cur)) latest[key] = r;
  }
  final out = <String, MessageReactions>{};
  for (final r in latest.values) {
    if (r.emoji.isEmpty) continue; // removed
    final byEmoji = out.putIfAbsent(r.target, () => {});
    (byEmoji[r.emoji] ??= []).add(r.author);
  }
  return out;
}

bool _isNewer(GroupReaction a, GroupReaction b) {
  if (a.createdAtMs != b.createdAtMs) return a.createdAtMs > b.createdAtMs;
  final h = a.author.hex.compareTo(b.author.hex);
  if (h != 0) return h > 0;
  return a.seq > b.seq;
}
