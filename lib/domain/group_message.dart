// Group message-log entry (groups epic, phase 0, brick 3): a per-author,
// signed message in a group. Mirrors the 1:1 event-log shape (author + own
// monotonic seq + prev-hash chain) but many authors write into ONE group log;
// each entry is validated locally (author is a non-muted member at its
// policy version, signature ok) before it is shown — same discipline as the
// control-log.

import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'group_payload.dart';

/// An inline media attachment carried WHOLE inside a group message (groups
/// epic, phase 1, media brick 1). Unlike 1:1 media — which ships a tiny thumb
/// in the advert and fetches the full blob over the content-path — a group
/// member is not necessarily a 1:1 contact of the author, so the first media
/// brick embeds a size-capped image directly in the signed message so EVERY
/// member renders it with no fetch. The cap ([kInlineImageRawMax]) bounds the
/// per-image snapshot cost; incremental deltas (a later Ф0 item) will stop full
/// snapshots from re-shipping old images.
class GroupAttachment {
  const GroupAttachment({
    required this.kind,
    required this.dataB64,
    required this.w,
    required this.h,
    this.cid,
    this.name,
  });

  final String kind; // 'image' | 'sticker' | 'voice' | …
  final String dataB64; // base64 payload — or the micro-thumb in ref form
  final int w; // encoded pixel dimensions (durationMs for 'voice')
  final int h;
  final String? name;

  /// Content-path reference (doc/GROUPS-CONTENT-PATH.md): when set, [dataB64]
  /// carries only a micro-thumb and the full bytes are fetched by this
  /// contentId over the membership-authorized stream pull. In the signed
  /// canonical bytes ONLY when present, so pre-content-path messages keep
  /// signing byte-identically (a ref-carrying message won't verify on builds
  /// predating the field — they reject rather than mis-render, RULE-WC-style).
  final String? cid;

  /// Canonical, order-stable map — folded into the message the author signs.
  Map<String, dynamic> toCanonical() => {
    'k': kind,
    'd': dataB64,
    'w': w,
    'h': h,
    if (cid != null) 'cid': cid,
    if (name != null) 'n': name,
  };

  Map<String, dynamic> toJson() => toCanonical();

  static GroupAttachment? fromJson(Object? j) {
    if (j is! Map) return null;
    final k = j['k'], d = j['d'], w = j['w'], h = j['h'];
    if (k is! String || d is! String || w is! int || h is! int) return null;
    if (w <= 0 || h <= 0 || d.isEmpty) return null;
    final cid = j['cid'];
    final name = j['n'];
    return GroupAttachment(
      kind: k,
      dataB64: d,
      w: w,
      h: h,
      cid: cid is String && cid.isNotEmpty ? cid : null,
      name: name is String && name.isNotEmpty ? name : null,
    );
  }
}

/// Decrypted message content. V2 entries encode this object only in RAM before
/// AEAD encryption and after authenticated decryption; [GroupMessage.toJson]
/// never serializes it for an encrypted entry.
class GroupMessageCleartext {
  const GroupMessageCleartext({
    required this.body,
    this.attachment,
    this.replyTo,
  });

  final String body;
  final GroupAttachment? attachment;
  final String? replyTo;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'body': body,
        if (attachment != null) 'att': attachment!.toJson(),
        if (replyTo != null) 'rt': replyTo,
      }),
    ),
  );

  static GroupMessageCleartext? decode(Uint8List bytes) {
    if (bytes.length > maxGroupEncryptedPayloadBytes) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (value is! Map || value['v'] != 1 || value['body'] is! String) {
        return null;
      }
      final attachment = value.containsKey('att')
          ? GroupAttachment.fromJson(value['att'])
          : null;
      if (value.containsKey('att') && attachment == null) return null;
      final replyTo = value['rt'];
      if (replyTo != null && replyTo is! String) return null;
      return GroupMessageCleartext(
        body: value['body'] as String,
        attachment: attachment,
        replyTo: replyTo as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

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
    this.version = 1,
    this.membershipEpoch,
    this.encryptedPayload,
    this.attachment,
    this.replyTo,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId groupId;
  final int version;
  final NodeId author;
  final int seq; // this author's monotonic message seq
  final String prevHash; // hex of the author's previous message hash, or ''
  final String body;
  final int? membershipEpoch;
  final GroupEncryptedPayload? encryptedPayload;
  final int policyVersion; // the policy version the author wrote against
  final int createdAtMs;
  final Uint8List signature;
  final GroupAttachment? attachment; // optional inline media
  /// The `<authorHex>:<seq>` reference of the message this one replies to, or
  /// null. Group messages have no single id, but (author, seq) is a permanent
  /// identity (groups have no edit/delete), so it resolves stably on any device.
  final String? replyTo;
  final Uint8List authorPubKey; // bound via node_id == BLAKE3(pk), not signed

  /// This message's own stable reference, for another message to [replyTo].
  String get ref => '${author.hex}:$seq';

  bool get isEncrypted =>
      version == 2 && membershipEpoch != null && encryptedPayload != null;

  /// The bytes the author signs — fixed field order, no signature/pubKey. The
  /// 'att'/'rt' keys are emitted ONLY when present, so a plain text message
  /// signs byte-identically to before these fields existed.
  Uint8List canonicalBytes() {
    final map = version == 2
        ? {
            'v': 2,
            'gid': groupId.hex,
            'author': author.hex,
            'seq': seq,
            'prev': prevHash,
            'epoch': membershipEpoch,
            'enc': encryptedPayload?.toJson(),
            'pv': policyVersion,
            'ts': createdAtMs,
          }
        : {
            'gid': groupId.hex,
            'author': author.hex,
            'seq': seq,
            'prev': prevHash,
            'body': body,
            'pv': policyVersion,
            'ts': createdAtMs,
            if (attachment != null) 'att': attachment!.toCanonical(),
            if (replyTo != null) 'rt': replyTo,
          };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  GroupMessage withSignature(Uint8List sig, Uint8List pubKey) => GroupMessage(
    groupId: groupId,
    author: author,
    seq: seq,
    prevHash: prevHash,
    body: body,
    version: version,
    membershipEpoch: membershipEpoch,
    encryptedPayload: encryptedPayload,
    policyVersion: policyVersion,
    createdAtMs: createdAtMs,
    signature: sig,
    attachment: attachment,
    replyTo: replyTo,
    authorPubKey: pubKey,
  );

  GroupMessage withDecryptedContent(GroupMessageCleartext cleartext) =>
      GroupMessage(
        groupId: groupId,
        author: author,
        seq: seq,
        prevHash: prevHash,
        body: cleartext.body,
        version: version,
        membershipEpoch: membershipEpoch,
        encryptedPayload: encryptedPayload,
        policyVersion: policyVersion,
        createdAtMs: createdAtMs,
        signature: signature,
        attachment: cleartext.attachment,
        replyTo: cleartext.replyTo,
        authorPubKey: authorPubKey,
      );

  Map<String, dynamic> toJson() {
    if (version == 2) {
      return {
        'v': 2,
        'gid': groupId.hex,
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'epoch': membershipEpoch,
        'enc': encryptedPayload?.toJson(),
        'pv': policyVersion,
        'ts': createdAtMs,
        'sig': base64Encode(signature),
        if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
      };
    }
    return {
      'gid': groupId.hex,
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'body': body,
      'pv': policyVersion,
      'ts': createdAtMs,
      if (attachment != null) 'att': attachment!.toJson(),
      if (replyTo != null) 'rt': replyTo,
      'sig': base64Encode(signature),
      if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
    };
  }

  static GroupMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final version = j['v'] is int ? j['v'] as int : 1;
    if (version != 1 && version != 2) return null;
    final gid = j['gid'], author = j['author'], seq = j['seq'];
    final prev = j['prev'], body = j['body'], pv = j['pv'], ts = j['ts'];
    final sig = j['sig'];
    if (gid is! String ||
        author is! String ||
        seq is! int ||
        prev is! String ||
        pv is! int ||
        ts is! int ||
        sig is! String ||
        seq < 0) {
      return null;
    }
    final encryptedPayload = version == 2
        ? GroupEncryptedPayload.fromJson(j['enc'])
        : null;
    final membershipEpoch = version == 2 ? j['epoch'] : null;
    if ((version == 1 && body is! String) ||
        (version == 2 &&
            (membershipEpoch is! int ||
                membershipEpoch < 0 ||
                encryptedPayload == null ||
                j.containsKey('body') ||
                j.containsKey('att') ||
                j.containsKey('rt')))) {
      return null;
    }
    try {
      return GroupMessage(
        groupId: NodeId.fromHex(gid),
        author: NodeId.fromHex(author),
        seq: seq,
        prevHash: prev,
        body: version == 1 ? body as String : '',
        version: version,
        membershipEpoch: membershipEpoch as int?,
        encryptedPayload: encryptedPayload,
        policyVersion: pv,
        createdAtMs: ts,
        signature: Uint8List.fromList(base64Decode(sig)),
        attachment: version == 1 ? GroupAttachment.fromJson(j['att']) : null,
        replyTo: version == 1 && j['rt'] is String ? j['rt'] as String : null,
        authorPubKey: j['apk'] is String
            ? Uint8List.fromList(base64Decode(j['apk'] as String))
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}
