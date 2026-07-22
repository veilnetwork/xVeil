// Groups content path, brick 1 (doc/GROUPS-CONTENT-PATH.md): the signed
// membership-authorized fetch request + the holder-side authorization gate.
// Pure domain — signing is injected (native ed25519 via group_crypto), no wire
// yet. The wire brick will carry [GroupContentRequest] in a new frame kind and
// admit the stream-pull session through [authorizeGroupContentRequest] instead
// of the 1:1 ContactStatus.accepted gate.

import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'group_policy.dart' show GroupState;

/// How long a signed request stays fresh. Short enough that a captured frame
/// is useless soon after (and immediately after a ban once the control delta
/// folds), long enough for clock skew between devices.
const Duration kGroupContentRequestWindow = Duration(minutes: 10);

/// A member's signed claim "I, [requester], may fetch [contentId] of
/// [groupId]". Signed with the same node-id-bound ed25519 identity that signs
/// the member's group messages.
class GroupContentRequest {
  GroupContentRequest({
    required this.groupId,
    required this.contentId,
    required this.requester,
    required this.nonce,
    required this.tsMs,
    required this.signature,
    this.channelId,
    this.channelEpoch,
    Uint8List? authorPubKey,
  }) : assert(
         (channelId == null) == (channelEpoch == null),
         'channel scope must be complete',
       ),
       authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId groupId;
  final String contentId; // hex id of the referenced content (as in 1:1)
  final NodeId requester;
  final String nonce; // random hex — replay dedup key at the holder
  final int tsMs; // request mint time (freshness window)
  /// Optional protected-channel scope. Both fields are signed together.
  ///
  /// An unscoped request can only unlock open-channel/post content. Restricted
  /// content requires the current channel epoch so a captured request stops
  /// authorizing immediately after an ACL rotation.
  final NodeId? channelId;
  final int? channelEpoch;
  final Uint8List signature;
  final Uint8List authorPubKey; // bound via node_id == BLAKE3(pk), not signed

  /// The bytes the requester signs — fixed field order, no signature/pubKey.
  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'gid': groupId.hex,
        'cid': contentId,
        'req': requester.hex,
        'n': nonce,
        'ts': tsMs,
        if (channelId != null) 'chid': channelId!.hex,
        if (channelEpoch != null) 'cep': channelEpoch,
      }),
    ),
  );

  GroupContentRequest withSignature(Uint8List sig, Uint8List pubKey) =>
      GroupContentRequest(
        groupId: groupId,
        contentId: contentId,
        requester: requester,
        nonce: nonce,
        tsMs: tsMs,
        channelId: channelId,
        channelEpoch: channelEpoch,
        signature: sig,
        authorPubKey: pubKey,
      );

  Map<String, dynamic> toJson() => {
    'gid': groupId.hex,
    'cid': contentId,
    'req': requester.hex,
    'n': nonce,
    'ts': tsMs,
    if (channelId != null) 'chid': channelId!.hex,
    if (channelEpoch != null) 'cep': channelEpoch,
    'sig': base64Encode(signature),
    if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
  };

  static GroupContentRequest? fromJson(Object? j) {
    if (j is! Map) return null;
    final gid = j['gid'], cid = j['cid'], req = j['req'];
    final n = j['n'], ts = j['ts'], sig = j['sig'];
    final channelId = j['chid'];
    final channelEpoch = j['cep'];
    if (gid is! String ||
        cid is! String ||
        req is! String ||
        n is! String ||
        ts is! int ||
        sig is! String ||
        cid.isEmpty ||
        n.isEmpty ||
        ((channelId == null) != (channelEpoch == null)) ||
        (channelId != null && channelId is! String) ||
        (channelEpoch != null && (channelEpoch is! int || channelEpoch <= 0))) {
      return null;
    }
    try {
      return GroupContentRequest(
        groupId: NodeId.fromHex(gid),
        contentId: cid,
        requester: NodeId.fromHex(req),
        nonce: n,
        tsMs: ts,
        channelId: channelId is String ? NodeId.fromHex(channelId) : null,
        channelEpoch: channelEpoch as int?,
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

/// Why a request was refused. The holder NEVER sends these to the requester
/// (canon: unauthorized requests are dropped silently — no membership oracle);
/// they exist for local logging and tests.
enum GroupContentDenial {
  badSignature,
  notAMember,
  notAuthorizedForScope,
  unknownContent,
  stale,
  replayed,
}

/// The holder-side gate: authorize [r] against the holder's OWN view — its
/// folded [state], the set of contentIds actually [referenced] by that group's
/// messages, the local clock [nowMs], and the bounded [seenNonces] replay
/// cache (the caller owns it and adds the nonce on success). Deterministic and
/// local: leave/remove/ban stops authorizing as soon as the control delta
/// folds at this holder.
GroupContentDenial? authorizeGroupContentRequest(
  GroupContentRequest r, {
  required GroupState state,
  required Set<String> referenced,
  required int nowMs,
  required Set<String> seenNonces,
  required bool Function(GroupContentRequest) verify,
  required bool scopeAuthorized,
}) {
  if (!verify(r)) return GroupContentDenial.badSignature;
  if (!state.isMember(r.requester)) return GroupContentDenial.notAMember;
  if (!scopeAuthorized) return GroupContentDenial.notAuthorizedForScope;
  if (!referenced.contains(r.contentId)) {
    return GroupContentDenial.unknownContent;
  }
  if ((nowMs - r.tsMs).abs() > kGroupContentRequestWindow.inMilliseconds) {
    return GroupContentDenial.stale;
  }
  if (seenNonces.contains(r.nonce)) return GroupContentDenial.replayed;
  return null; // authorized
}
