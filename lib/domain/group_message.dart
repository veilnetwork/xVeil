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
import 'chat.dart' show kMessageClockSkew;
import 'group_payload.dart';
import 'inline_custom_emoji.dart';
import 'media_object.dart';

export 'media_object.dart' show GroupAttachment, MediaObject;

/// The value a group/Space row claiming [claimedMs] is ORDERED by locally,
/// given that this device first saw it at [receivedAtMs].
///
/// A group message is ranked, previewed and counted on `ts` — a number the
/// AUTHOR chose. Nothing authenticates it: the signature proves who wrote the
/// number, never that the clock behind it was honest, and this network issues
/// no time. One member therefore stamps itself years ahead and owns the bottom
/// of that chat, its row in the chat list, the mention inbox, and an unread
/// badge that can no longer be cleared — all of it until that stamp arrives.
///
/// The 1:1 answer — rewrite the stored stamp ([messageTsOnReceipt]) — is NOT
/// available here, and that is the whole reason this rule exists separately:
/// [GroupMessage.canonicalBytes] includes `'ts'` and is signed, so a receiver
/// that rewrote it would invalidate every signature in the log and take the
/// group's admission rules down with them. So the signed number is left exactly
/// as its author wrote it, keeps being verified, keeps being what retention and
/// the ACL's `atMs` ask about — and ORDER is taken from this derived value
/// instead.
///
/// Not the deferral device-sync events get (`deviceSyncEffectiveAt`) either. A
/// deferred sync event is HIDDEN until its own time comes, which is right when
/// the row would otherwise win a key and delete the honest rows it beat. A
/// message wins nothing and suppresses nothing, so deferring it would only
/// hide a legitimate message from a slightly-fast device for some minutes —
/// and an unread message no one can see is worse than a message shown in the
/// wrong place.
///
/// One-sided, like the 1:1 rule: a stamp in the PAST is left alone. It cannot
/// float above anything, and a device back from a week offline must keep last
/// Tuesday.
///
/// [receivedAtMs] must be the moment the row was FIRST accepted here, recorded
/// once and persisted; passing a live clock would re-derive a larger value on
/// every read and walk the row down the log each time the screen is opened,
/// which is the failure this exists to prevent.
///
/// [kMessageClockSkew] is deliberately the 1:1 message tolerance rather than a
/// fourth constant: the question is the same one ("how far ahead may a sender
/// claim to be and still be believed"), and the project keeps one skew
/// convention (`kSpacePublicClockSkew`, `kDeviceSyncClockSkew`).
int groupMessageOrderAt(int claimedMs, int receivedAtMs) =>
    claimedMs > receivedAtMs + kMessageClockSkew.inMilliseconds
    ? receivedAtMs
    : claimedMs;

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
    this.editOf,
    this.deleteOf,
    this.customEmoji = const [],
  });

  final String body;
  final MediaObject? attachment;
  final String? replyTo;
  final String? editOf;
  final String? deleteOf;
  final List<InlineCustomEmoji> customEmoji;

  Uint8List encode() {
    final isEdit = editOf != null;
    final isDelete = deleteOf != null;
    if (isEdit && isDelete) {
      throw ArgumentError('comment edit and delete are mutually exclusive');
    }
    if (isEdit &&
        (!_spacePostCommentTargetPattern.hasMatch(editOf!) ||
            attachment != null ||
            replyTo != null)) {
      throw ArgumentError.value(editOf, 'editOf', 'invalid comment edit');
    }
    if (isDelete &&
        (!_spacePostCommentTargetPattern.hasMatch(deleteOf!) ||
            body.isNotEmpty ||
            attachment != null ||
            replyTo != null ||
            customEmoji.isNotEmpty)) {
      throw ArgumentError.value(deleteOf, 'deleteOf', 'invalid comment delete');
    }
    final referenceMedia =
        attachment != null &&
        attachment!.inlinePreviewB64 == null &&
        attachment!.isReferenceStructurallyValid;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': isDelete
              ? 4
              : isEdit
              ? 3
              : referenceMedia
              ? 2
              : 1,
          'body': body,
          if (!isEdit && !isDelete && referenceMedia)
            'media': attachment!.toReferenceJson(),
          if (!isEdit && !isDelete && !referenceMedia && attachment != null)
            'att': attachment!.toLegacyAttachmentCanonical(),
          if (!isEdit && !isDelete && replyTo != null) 'rt': replyTo,
          if (isEdit) 'edit': editOf,
          if (isDelete) 'delete': deleteOf,
          if (!isDelete && customEmoji.isNotEmpty)
            'ce': encodeInlineCustomEmoji(customEmoji),
        }),
      ),
    );
  }

  static GroupMessageCleartext? decode(Uint8List bytes) {
    if (bytes.length > maxGroupEncryptedPayloadBytes) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (value is! Map ||
          (value['v'] != 1 &&
              value['v'] != 2 &&
              value['v'] != 3 &&
              value['v'] != 4) ||
          value['body'] is! String) {
        return null;
      }
      final isEdit = value['v'] == 3;
      final isDelete = value['v'] == 4;
      final referenceMedia = value['v'] == 2;
      if ((referenceMedia && value.containsKey('att')) ||
          (!referenceMedia && value.containsKey('media')) ||
          (isEdit &&
              (value.containsKey('att') ||
                  value.containsKey('media') ||
                  value.containsKey('rt'))) ||
          (!isEdit && value.containsKey('edit')) ||
          (isDelete &&
              (value['body'] != '' ||
                  value.containsKey('att') ||
                  value.containsKey('media') ||
                  value.containsKey('rt') ||
                  value.containsKey('edit') ||
                  value.containsKey('ce'))) ||
          (!isDelete && value.containsKey('delete'))) {
        return null;
      }
      final attachment = referenceMedia
          ? MediaObject.fromReferenceJson(value['media'])
          : value.containsKey('att')
          ? MediaObject.fromLegacyAttachmentJson(value['att'])
          : null;
      if ((referenceMedia || value.containsKey('att')) && attachment == null) {
        return null;
      }
      final replyTo = value['rt'];
      if (replyTo != null && replyTo is! String) return null;
      final editOf = value['edit'];
      if (isEdit &&
          (editOf is! String ||
              !_spacePostCommentTargetPattern.hasMatch(editOf))) {
        return null;
      }
      final deleteOf = value['delete'];
      if (isDelete &&
          (deleteOf is! String ||
              !_spacePostCommentTargetPattern.hasMatch(deleteOf))) {
        return null;
      }
      return GroupMessageCleartext(
        body: value['body'] as String,
        attachment: attachment,
        replyTo: replyTo as String?,
        editOf: editOf as String?,
        deleteOf: deleteOf as String?,
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
    MediaObject? attachment,
    this.replyTo,
    this.editOf,
    this.deleteOf,
    this.customEmoji = const [],
    this.lifecycleGeneration,
    this.mediaHiddenByRetention = false,
    int? orderedAtMs,
    Uint8List? authorPubKey,
  }) : // A public `attachment` parameter intentionally feeds a private raw
       // field; the public getter applies the retention projection.
       // ignore: prefer_initializing_formals
       _attachment = attachment,
       // Same reason: a named parameter cannot be private, so the projection
       // is taken under a public name and kept in a private field.
       // ignore: prefer_initializing_formals
       _orderedAtMs = orderedAtMs,
       authorPubKey = authorPubKey ?? Uint8List(0);

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
  final MediaObject? _attachment; // signed/decrypted inline or referenced media

  /// Projection-only marker. The signed row and its raw attachment remain
  /// intact for verification/replication, while user-facing consumers see no
  /// media reference after an irreversible media-only retention boundary.
  final bool mediaHiddenByRetention;

  MediaObject? get attachment => mediaHiddenByRetention ? null : _attachment;

  /// Projection-only, exactly like [mediaHiddenByRetention]: never signed,
  /// never serialized, never on the wire. Absent on a raw stored row.
  final int? _orderedAtMs;

  /// What this row is ORDERED, previewed and counted by locally: its own
  /// [createdAtMs], unless the receiving device could not believe that stamp
  /// when the row arrived (see [groupMessageOrderAt]), in which case the moment
  /// it arrived.
  ///
  /// [createdAtMs] stays untouched and stays authoritative for everything the
  /// AUTHOR's word governs — the signature, retention boundaries, the ACL's
  /// `atMs`, channel history windows — because those are questions about what
  /// was signed. This is only the answer to "where does it go on screen".
  int get orderedAtMs => _orderedAtMs ?? createdAtMs;
  final List<InlineCustomEmoji> customEmoji;

  /// The `<authorHex>:<seq>` reference of the message this one replies to, or
  /// null. Group messages have no single id, but (author, seq) is a permanent
  /// identity; comment edits append revisions and keep this root stable.
  final String? replyTo;

  /// Stable root-comment reference changed by this immutable row. It is kept
  /// inside the encrypted cleartext, so observers cannot correlate edits.
  final String? editOf;

  /// Stable root-comment reference removed by this immutable tombstone. Like
  /// [editOf], it exists only after authenticated decryption and is never
  /// serialized by an encrypted outer [GroupMessage].
  final String? deleteOf;
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
            if (_attachment != null)
              'att': _attachment.toLegacyAttachmentCanonical(),
            if (replyTo != null) 'rt': replyTo,
            if (editOf != null) 'edit': editOf,
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
    attachment: _attachment,
    replyTo: replyTo,
    editOf: editOf,
    deleteOf: deleteOf,
    customEmoji: customEmoji,
    lifecycleGeneration: lifecycleGeneration,
    mediaHiddenByRetention: mediaHiddenByRetention,
    orderedAtMs: _orderedAtMs,
    authorPubKey: pubKey,
  );

  /// Attach the local display order derived for this row. Touches nothing the
  /// author signed: [canonicalBytes] and [toJson] are byte-identical before and
  /// after, so a signature made before this projection existed still verifies
  /// and [groupMessageHash] still names the same row.
  GroupMessage withOrderedAt(int ms) => GroupMessage(
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
    signature: signature,
    attachment: _attachment,
    replyTo: replyTo,
    editOf: editOf,
    deleteOf: deleteOf,
    customEmoji: customEmoji,
    lifecycleGeneration: lifecycleGeneration,
    mediaHiddenByRetention: mediaHiddenByRetention,
    orderedAtMs: ms,
    authorPubKey: authorPubKey,
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
        editOf: cleartext.editOf,
        deleteOf: cleartext.deleteOf,
        customEmoji: cleartext.customEmoji,
        lifecycleGeneration: lifecycleGeneration,
        orderedAtMs: _orderedAtMs,
        authorPubKey: authorPubKey,
      );

  GroupMessage withMediaHiddenByRetention() => mediaHiddenByRetention
      ? this
      : GroupMessage(
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
          signature: signature,
          attachment: _attachment,
          replyTo: replyTo,
          editOf: editOf,
          deleteOf: deleteOf,
          customEmoji: customEmoji,
          lifecycleGeneration: lifecycleGeneration,
          mediaHiddenByRetention: true,
          orderedAtMs: _orderedAtMs,
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
      if (_attachment != null) 'att': _attachment.toLegacyAttachmentCanonical(),
      if (replyTo != null) 'rt': replyTo,
      if (editOf != null) 'edit': editOf,
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
    final editOf = j['edit'];
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
        (editOf != null &&
            (editOf is! String ||
                !_spacePostCommentTargetPattern.hasMatch(editOf) ||
                spacePostId == null ||
                j.containsKey('att') ||
                j.containsKey('rt'))) ||
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
                j.containsKey('edit') ||
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
                j.containsKey('edit') ||
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
        editOf: (version == 1 || version == 4) && editOf is String
            ? editOf
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

/// Stable, user-facing projection of one Space-post comment and its latest
/// valid immutable edit. Replies keep targeting [ref], while the original
/// signed row remains available in the replicated log.
class SpacePostCommentView {
  const SpacePostCommentView({required this.root, this.revision});

  final GroupMessage root;
  final GroupMessage? revision;

  String get ref => root.ref;
  NodeId get author => root.author;
  String get body => revision?.body ?? root.body;
  MediaObject? get attachment => root.attachment;
  bool get mediaHiddenByRetention => root.mediaHiddenByRetention;
  String? get replyTo => root.replyTo;
  String? get spacePostId => root.spacePostId;
  int get createdAtMs => root.createdAtMs;
  bool get edited => revision != null;
  int? get editedAtMs => revision?.createdAtMs;
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
