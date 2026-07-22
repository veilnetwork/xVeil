// Group reaction log (groups epic, phase 1): a per-author, signed reaction on a
// message. Like the message log, many authors write into ONE reaction log; each
// is validated (author is a member, signature ok) before it counts. A reaction
// targets a message by its stable ref "<authorHex>:<seq>". An EMPTY emoji
// removes this author's reaction on that message (toggle) — the LATEST reaction
// per (author, target) wins, folded deterministically so every device agrees.

import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'group_payload.dart';

enum ReactionTargetKind {
  message,
  spacePost;

  static ReactionTargetKind? fromName(String value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

class GroupReactionCleartext {
  const GroupReactionCleartext({
    required this.target,
    required this.emoji,
    this.targetKind = ReactionTargetKind.message,
    this.schemaVersion = 1,
  });

  final String target;
  final String emoji;
  final ReactionTargetKind targetKind;
  final int schemaVersion;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        schemaVersion == 1
            ? {'v': 1, 'tgt': target, 'emoji': emoji}
            : {'v': 2, 'kind': targetKind.name, 'tgt': target, 'emoji': emoji},
      ),
    ),
  );

  static GroupReactionCleartext? decode(Uint8List bytes) {
    if (bytes.length > maxGroupEncryptedPayloadBytes) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (value is! Map ||
          (value['v'] != 1 && value['v'] != 2) ||
          value['tgt'] is! String ||
          value['emoji'] is! String) {
        return null;
      }
      final version = value['v'] as int;
      final kind = version == 1
          ? ReactionTargetKind.message
          : value['kind'] is String
          ? ReactionTargetKind.fromName(value['kind'] as String)
          : null;
      if (kind == null || (version == 1 && value.containsKey('kind'))) {
        return null;
      }
      return GroupReactionCleartext(
        target: value['tgt'] as String,
        emoji: value['emoji'] as String,
        targetKind: kind,
        schemaVersion: version,
      );
    } catch (_) {
      return null;
    }
  }
}

class GroupReaction {
  GroupReaction({
    required this.groupId,
    required this.author,
    required this.seq,
    required this.target,
    required this.emoji,
    required this.createdAtMs,
    required this.signature,
    this.version = 1,
    this.targetKind = ReactionTargetKind.message,
    this.membershipEpoch,
    this.encryptedPayload,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId groupId;
  final int version;
  final NodeId author;
  final int seq; // this author's monotonic reaction seq
  final String target; // "<authorHex>:<seq>" of the reacted message
  final String emoji; // '' = remove this author's reaction on [target]
  final ReactionTargetKind targetKind;
  final int? membershipEpoch;
  final GroupEncryptedPayload? encryptedPayload;
  final int createdAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey; // bound via node_id == BLAKE3(pk)

  bool get isEncrypted =>
      (version == 2 || version == 4) &&
      membershipEpoch != null &&
      encryptedPayload != null;

  bool get isStructurallyValid {
    if (seq < 0 || createdAtMs < 0 || version < 1 || version > 4) return false;
    if (version == 1 || version == 3) {
      return membershipEpoch == null &&
          encryptedPayload == null &&
          target.isNotEmpty &&
          utf8.encode(target).length <= 160 &&
          utf8.encode(emoji).length <= 64 &&
          (version == 3 || targetKind == ReactionTargetKind.message);
    }
    return membershipEpoch != null &&
        membershipEpoch! >= 0 &&
        encryptedPayload?.isStructurallyValid == true;
  }

  /// The bytes the author signs — fixed field order, no signature/pubKey.
  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        version == 2 || version == 4
            ? {
                'v': version,
                'gid': groupId.hex,
                'author': author.hex,
                'seq': seq,
                'epoch': membershipEpoch,
                'enc': encryptedPayload?.toJson(),
                'ts': createdAtMs,
              }
            : version == 3
            ? {
                'v': 3,
                'gid': groupId.hex,
                'author': author.hex,
                'seq': seq,
                'kind': targetKind.name,
                'tgt': target,
                'emoji': emoji,
                'ts': createdAtMs,
              }
            : {
                'gid': groupId.hex,
                'author': author.hex,
                'seq': seq,
                'tgt': target,
                'emoji': emoji,
                'ts': createdAtMs,
              },
      ),
    ),
  );

  GroupReaction withSignature(Uint8List sig, Uint8List pubKey) => GroupReaction(
    groupId: groupId,
    author: author,
    seq: seq,
    target: target,
    emoji: emoji,
    version: version,
    targetKind: targetKind,
    membershipEpoch: membershipEpoch,
    encryptedPayload: encryptedPayload,
    createdAtMs: createdAtMs,
    signature: sig,
    authorPubKey: pubKey,
  );

  GroupReaction withDecryptedContent(GroupReactionCleartext cleartext) =>
      GroupReaction(
        groupId: groupId,
        author: author,
        seq: seq,
        target: cleartext.target,
        emoji: cleartext.emoji,
        version: version,
        targetKind: cleartext.targetKind,
        membershipEpoch: membershipEpoch,
        encryptedPayload: encryptedPayload,
        createdAtMs: createdAtMs,
        signature: signature,
        authorPubKey: authorPubKey,
      );

  Map<String, dynamic> toJson() => version == 2 || version == 4
      ? {
          'v': version,
          'gid': groupId.hex,
          'author': author.hex,
          'seq': seq,
          'epoch': membershipEpoch,
          'enc': encryptedPayload?.toJson(),
          'ts': createdAtMs,
          'sig': base64Encode(signature),
          if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
        }
      : version == 3
      ? {
          'v': 3,
          'gid': groupId.hex,
          'author': author.hex,
          'seq': seq,
          'kind': targetKind.name,
          'tgt': target,
          'emoji': emoji,
          'ts': createdAtMs,
          'sig': base64Encode(signature),
          if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
        }
      : {
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
    final version = j['v'] is int ? j['v'] as int : 1;
    if (version < 1 || version > 4) return null;
    final gid = j['gid'], author = j['author'], seq = j['seq'];
    final tgt = j['tgt'], emoji = j['emoji'], ts = j['ts'], sig = j['sig'];
    final encrypted = version == 2 || version == 4;
    final typed = version == 3;
    final encryptedPayload = encrypted
        ? GroupEncryptedPayload.fromJson(j['enc'])
        : null;
    final membershipEpoch = encrypted ? j['epoch'] : null;
    final kind = typed
        ? j['kind'] is String
              ? ReactionTargetKind.fromName(j['kind'] as String)
              : null
        : ReactionTargetKind.message;
    if (gid is! String ||
        author is! String ||
        seq is! int ||
        ts is! int ||
        sig is! String ||
        seq < 0 ||
        kind == null ||
        (!encrypted && (tgt is! String || emoji is! String)) ||
        (version == 1 && j.containsKey('kind')) ||
        (!encrypted && (j.containsKey('epoch') || j.containsKey('enc'))) ||
        (encrypted &&
            (membershipEpoch is! int ||
                membershipEpoch < 0 ||
                encryptedPayload == null ||
                j.containsKey('tgt') ||
                j.containsKey('emoji') ||
                j.containsKey('kind')))) {
      return null;
    }
    try {
      return GroupReaction(
        groupId: NodeId.fromHex(gid),
        author: NodeId.fromHex(author),
        seq: seq,
        target: encrypted ? '' : tgt as String,
        emoji: encrypted ? '' : emoji as String,
        version: version,
        targetKind: kind,
        membershipEpoch: membershipEpoch as int?,
        encryptedPayload: encryptedPayload,
        createdAtMs: ts,
        signature: Uint8List.fromList(base64Decode(sig)),
        authorPubKey: j['apk'] is String
            ? Uint8List.fromList(base64Decode(j['apk'] as String))
            : null,
      ).._assertStructural();
    } catch (_) {
      return null;
    }
  }

  void _assertStructural() {
    if (!isStructurallyValid) throw const FormatException('invalid reaction');
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
) => foldReactionsByKind(reactions, verify, ReactionTargetKind.message);

/// Fold only one target namespace. Legacy rows always belong to [message], so
/// a message ref and a Space post id can never overwrite each other.
Map<String, MessageReactions> foldReactionsByKind(
  Iterable<GroupReaction> reactions,
  bool Function(GroupReaction) verify,
  ReactionTargetKind kind,
) {
  // Latest reaction per (author, target).
  final latest = <String, GroupReaction>{};
  for (final r in reactions) {
    if (r.targetKind != kind || !verify(r)) continue;
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

/// The fold ordering exposed to storage compaction. A compactor must retain
/// exactly the same winner as [foldGroupReactions], otherwise a fresh device
/// could reconstruct a different reaction state from the compacted snapshot.
bool isNewerGroupReaction(GroupReaction a, GroupReaction b) => _isNewer(a, b);
