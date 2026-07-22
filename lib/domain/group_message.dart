// Group message-log entry (groups epic, phase 0, brick 3): a per-author,
// signed message in a group. Mirrors the 1:1 event-log shape (author + own
// monotonic seq + prev-hash chain) but many authors write into ONE group log;
// each entry is validated locally (author is a non-muted member at its
// policy version, signature ok) before it is shown — same discipline as the
// control-log.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'group_payload.dart';
import 'inline_custom_emoji.dart';
import 'media_object.dart';

export 'media_object.dart' show GroupAttachment, MediaObject;

final RegExp _spacePostCommentTargetPattern = RegExp(r'^[0-9a-f]{64}:[0-9]+$');

/// Text-only V1 discussion payload ceiling. The transport already has a
/// bounded encrypted payload, but keeping the product limit explicit lets UI,
/// REST and the authoritative service reject oversized input consistently.
const int kSpacePostCommentMaxBytes = 512 * 1024;

/// Decrypted message content. V2 entries encode this object only in RAM before
/// AEAD encryption and after authenticated decryption; [GroupMessage.toJson]
/// never serializes it for an encrypted entry.
class GroupMessageCleartext {
  const GroupMessageCleartext({
    required this.body,
    this.attachment,
    this.replyTo,
    this.customEmoji = const [],
  });

  final String body;
  final MediaObject? attachment;
  final String? replyTo;
  final List<InlineCustomEmoji> customEmoji;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'body': body,
        if (attachment != null)
          'att': attachment!.toLegacyAttachmentCanonical(),
        if (replyTo != null) 'rt': replyTo,
        if (customEmoji.isNotEmpty) 'ce': encodeInlineCustomEmoji(customEmoji),
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
          ? MediaObject.fromLegacyAttachmentJson(value['att'])
          : null;
      if (value.containsKey('att') && attachment == null) return null;
      final replyTo = value['rt'];
      if (replyTo != null && replyTo is! String) return null;
      return GroupMessageCleartext(
        body: value['body'] as String,
        attachment: attachment,
        replyTo: replyTo as String?,
        customEmoji: parseInlineCustomEmoji(
          value['body'] as String,
          value['ce'],
        ),
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
    this.channelEpoch,
    this.encryptedPayload,
    this.channelId,
    this.spacePostId,
    this.attachment,
    this.replyTo,
    this.customEmoji = const [],
    this.lifecycleGeneration,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId groupId;
  final int version;
  final NodeId author;
  final int seq; // this author's monotonic message seq
  final String prevHash; // hex of the author's previous message hash, or ''
  final String body;
  final int? membershipEpoch;
  final int? channelEpoch;
  final GroupEncryptedPayload? encryptedPayload;
  final NodeId? channelId;

  /// Root publication this row comments on. Comments intentionally reuse the
  /// Space's signed per-author message log, epoch E2EE and anti-entropy, but
  /// have a disjoint chain scope and never materialize as channel messages.
  final String? spacePostId;
  final int policyVersion; // the policy version the author wrote against
  final int createdAtMs;
  final String? lifecycleGeneration;
  final Uint8List signature;
  final MediaObject? attachment; // optional inline/ref media
  final List<InlineCustomEmoji> customEmoji;

  /// The `<authorHex>:<seq>` reference of the message this one replies to, or
  /// null. Group messages have no single id, but (author, seq) is a permanent
  /// identity (groups have no edit/delete), so it resolves stably on any device.
  final String? replyTo;
  final Uint8List authorPubKey; // bound via node_id == BLAKE3(pk), not signed

  /// This message's own stable reference, for another message to [replyTo].
  String get ref => '${author.hex}:$seq';

  bool get isEncrypted =>
      (((version == 2 || version == 5) &&
              membershipEpoch != null &&
              channelEpoch == null) ||
          ((version == 3 || version == 6) &&
              membershipEpoch == null &&
              channelEpoch != null)) &&
      encryptedPayload != null;

  bool get isChannelEncrypted =>
      (version == 3 || version == 6) &&
      channelId != null &&
      membershipEpoch == null &&
      channelEpoch != null &&
      encryptedPayload != null;

  /// The bytes the author signs — fixed field order, no signature/pubKey. The
  /// 'att'/'rt' keys are emitted ONLY when present, so a plain text message
  /// signs byte-identically to before these fields existed.
  Uint8List canonicalBytes() {
    final map = version == 3 || version == 6
        ? {
            'v': version,
            'gid': groupId.hex,
            'channel': channelId?.hex,
            'author': author.hex,
            'seq': seq,
            'prev': prevHash,
            'cepoch': channelEpoch,
            'enc': encryptedPayload?.toJson(),
            if (version == 6) 'lifecycle': lifecycleGeneration,
            'pv': policyVersion,
            'ts': createdAtMs,
          }
        : version == 2 || version == 5
        ? {
            'v': version,
            'gid': groupId.hex,
            if (channelId != null) 'channel': channelId!.hex,
            if (spacePostId != null) 'post': spacePostId,
            'author': author.hex,
            'seq': seq,
            'prev': prevHash,
            'epoch': membershipEpoch,
            'enc': encryptedPayload?.toJson(),
            if (version == 5) 'lifecycle': lifecycleGeneration,
            'pv': policyVersion,
            'ts': createdAtMs,
          }
        : {
            if (version == 4) 'v': 4,
            'gid': groupId.hex,
            if (channelId != null) 'channel': channelId!.hex,
            if (spacePostId != null) 'post': spacePostId,
            'author': author.hex,
            'seq': seq,
            'prev': prevHash,
            'body': body,
            'pv': policyVersion,
            'ts': createdAtMs,
            if (attachment != null)
              'att': attachment!.toLegacyAttachmentCanonical(),
            if (replyTo != null) 'rt': replyTo,
            if (customEmoji.isNotEmpty)
              'ce': encodeInlineCustomEmoji(customEmoji),
            if (version == 4) 'lifecycle': lifecycleGeneration,
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
    channelEpoch: channelEpoch,
    encryptedPayload: encryptedPayload,
    channelId: channelId,
    spacePostId: spacePostId,
    policyVersion: policyVersion,
    createdAtMs: createdAtMs,
    signature: sig,
    attachment: attachment,
    replyTo: replyTo,
    customEmoji: customEmoji,
    lifecycleGeneration: lifecycleGeneration,
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
        channelEpoch: channelEpoch,
        encryptedPayload: encryptedPayload,
        channelId: channelId,
        spacePostId: spacePostId,
        policyVersion: policyVersion,
        createdAtMs: createdAtMs,
        signature: signature,
        attachment: cleartext.attachment,
        replyTo: cleartext.replyTo,
        customEmoji: cleartext.customEmoji,
        lifecycleGeneration: lifecycleGeneration,
        authorPubKey: authorPubKey,
      );

  Map<String, dynamic> toJson() {
    if (version == 3 || version == 6) {
      return {
        'v': version,
        'gid': groupId.hex,
        'channel': channelId?.hex,
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'cepoch': channelEpoch,
        'enc': encryptedPayload?.toJson(),
        if (version == 6) 'lifecycle': lifecycleGeneration,
        'pv': policyVersion,
        'ts': createdAtMs,
        'sig': base64Encode(signature),
        if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
      };
    }
    if (version == 2 || version == 5) {
      return {
        'v': version,
        'gid': groupId.hex,
        if (channelId != null) 'channel': channelId!.hex,
        if (spacePostId != null) 'post': spacePostId,
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'epoch': membershipEpoch,
        'enc': encryptedPayload?.toJson(),
        if (version == 5) 'lifecycle': lifecycleGeneration,
        'pv': policyVersion,
        'ts': createdAtMs,
        'sig': base64Encode(signature),
        if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
      };
    }
    return {
      if (version == 4) 'v': 4,
      'gid': groupId.hex,
      if (channelId != null) 'channel': channelId!.hex,
      if (spacePostId != null) 'post': spacePostId,
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'body': body,
      'pv': policyVersion,
      'ts': createdAtMs,
      if (attachment != null) 'att': attachment!.toLegacyAttachmentCanonical(),
      if (replyTo != null) 'rt': replyTo,
      if (customEmoji.isNotEmpty) 'ce': encodeInlineCustomEmoji(customEmoji),
      if (version == 4) 'lifecycle': lifecycleGeneration,
      'sig': base64Encode(signature),
      if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
    };
  }

  static GroupMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final version = j['v'] is int ? j['v'] as int : 1;
    if (version < 1 || version > 6) return null;
    final gid = j['gid'], author = j['author'], seq = j['seq'];
    final prev = j['prev'], body = j['body'], pv = j['pv'], ts = j['ts'];
    final sig = j['sig'];
    final spacePostId = j['post'];
    if (gid is! String ||
        author is! String ||
        seq is! int ||
        prev is! String ||
        pv is! int ||
        ts is! int ||
        sig is! String ||
        (spacePostId != null &&
            (spacePostId is! String ||
                !_spacePostCommentTargetPattern.hasMatch(spacePostId))) ||
        (spacePostId != null && j['channel'] != null) ||
        seq < 0) {
      return null;
    }
    final encryptedPayload = const {2, 3, 5, 6}.contains(version)
        ? GroupEncryptedPayload.fromJson(j['enc'])
        : null;
    final membershipEpoch = version == 2 || version == 5 ? j['epoch'] : null;
    final channelEpoch = version == 3 || version == 6 ? j['cepoch'] : null;
    final lifecycleScoped = version >= 4;
    final lifecycle = lifecycleScoped ? j['lifecycle'] : null;
    if ((lifecycleScoped &&
            (lifecycle is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(lifecycle))) ||
        (!lifecycleScoped && j.containsKey('lifecycle')) ||
        ((version == 1 || version == 4) &&
            (body is! String ||
                j.containsKey('epoch') ||
                j.containsKey('cepoch') ||
                j.containsKey('enc'))) ||
        ((version == 2 || version == 5) &&
            (membershipEpoch is! int ||
                membershipEpoch < 0 ||
                encryptedPayload == null ||
                j.containsKey('body') ||
                j.containsKey('att') ||
                j.containsKey('rt') ||
                j.containsKey('ce'))) ||
        ((version == 3 || version == 6) &&
            (channelEpoch is! int ||
                channelEpoch <= 0 ||
                channelEpoch > 0xffffffff ||
                j['channel'] is! String ||
                encryptedPayload == null ||
                j.containsKey('epoch') ||
                j.containsKey('body') ||
                j.containsKey('att') ||
                j.containsKey('rt') ||
                j.containsKey('ce')))) {
      return null;
    }
    try {
      return GroupMessage(
        groupId: NodeId.fromHex(gid),
        channelId: j['channel'] is String
            ? NodeId.fromHex(j['channel'] as String)
            : null,
        spacePostId: spacePostId as String?,
        author: NodeId.fromHex(author),
        seq: seq,
        prevHash: prev,
        body: version == 1 || version == 4 ? body as String : '',
        version: version,
        membershipEpoch: membershipEpoch as int?,
        channelEpoch: channelEpoch as int?,
        encryptedPayload: encryptedPayload,
        policyVersion: pv,
        createdAtMs: ts,
        signature: Uint8List.fromList(base64Decode(sig)),
        attachment: version == 1 || version == 4
            ? MediaObject.fromLegacyAttachmentJson(j['att'])
            : null,
        replyTo: (version == 1 || version == 4) && j['rt'] is String
            ? j['rt'] as String
            : null,
        customEmoji: version == 1 || version == 4
            ? parseInlineCustomEmoji(body as String, j['ce'])
            : const [],
        lifecycleGeneration: lifecycle as String?,
        authorPubKey: j['apk'] is String
            ? Uint8List.fromList(base64Decode(j['apk'] as String))
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Digest used by the per-author, per-visibility-scope message chain.
///
/// The signature is included so [GroupMessage.prevHash] commits to one exact
/// signed predecessor. Two valid signatures over otherwise identical payloads
/// therefore remain distinct fork evidence instead of collapsing into one
/// arrival-order-dependent row.
String groupMessageHash(GroupMessage message) => crypto.sha256.convert(<int>[
  ...message.canonicalBytes(),
  ...message.signature,
]).toString();
