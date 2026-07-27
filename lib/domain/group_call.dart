import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'call_signal.dart';
import 'group_payload.dart';

/// Version 1 is not historical: it is what every plain group call still
/// signals. Versions 2 and 3 are the Space voice-channel shapes.
const int kGroupCallProtocolVersion = 1;
const int kSpaceVoiceSessionProtocolVersion = 2;
const int kProtectedSpaceVoiceSessionProtocolVersion = 3;
const int maxGroupCallIdBytes = 128;
const int maxGroupCallSignalBytes = 4096;

/// Ephemeral group-call control events. They are deliberately transported
/// outside the persistent group message log: replaying history must never make
/// a device ring for an already-ended call.
enum GroupCallSignalType {
  announce,
  join,
  leave,
  end,
  heartbeat,
  renegotiate,
  busy,
  unknown,
}

T _enumFromIndex<T>(List<T> values, Object? raw, T fallback) {
  if (raw is num) {
    final index = raw.toInt();
    if (index >= 0 && index < values.length) return values[index];
  }
  return fallback;
}

/// A node-id-bound, signed group-call event before epoch encryption.
///
/// [nonce] is a 96-bit lowercase hex event id. It makes two repeated events of
/// the same type distinct and gives the receiver a replay key independent of
/// transport frame ids or ciphertext nonces.
class GroupCallSignal {
  GroupCallSignal({
    required this.groupId,
    this.channelId,
    this.channelEpoch,
    required this.callId,
    required this.author,
    required this.membershipEpoch,
    required this.type,
    required this.sentAtMs,
    required this.nonce,
    required this.signature,
    required this.authorPubKey,
    this.media,
    this.reason,
    this.protocolVersion = kGroupCallProtocolVersion,
  });

  final NodeId groupId;

  /// Present for v2/v3 Space voice sessions. Plain group rooms omit it.
  final NodeId? channelId;

  /// Present only for v3 restricted Space voice sessions.
  final int? channelEpoch;
  final String callId;
  final NodeId author;
  final int membershipEpoch;
  final GroupCallSignalType type;
  final CallMedia? media;
  final CallEndReason? reason;
  final int sentAtMs;
  final String nonce;
  final int protocolVersion;
  final Uint8List signature;
  final Uint8List authorPubKey;

  bool get isStructurallyValid {
    final callIdLength = utf8.encode(callId).length;
    // `media` is the non-empty room capability on announce/join. Heartbeat and
    // renegotiate carry the sender's CURRENT posture, which is legitimately
    // empty when both microphone and camera are off.
    final mediaValid =
        media == null ||
        !media!.isEmpty ||
        type == GroupCallSignalType.heartbeat ||
        type == GroupCallSignalType.renegotiate;
    final scopeValid = switch (protocolVersion) {
      kGroupCallProtocolVersion =>
        channelId == null && channelEpoch == null,
      kSpaceVoiceSessionProtocolVersion =>
        channelId != null && channelEpoch == null,
      kProtectedSpaceVoiceSessionProtocolVersion =>
        channelId != null &&
            channelEpoch != null &&
            channelEpoch! > 0 &&
            channelEpoch! <= 0xffffffff,
      _ => false,
    };
    return scopeValid &&
        membershipEpoch > 0 &&
        membershipEpoch <= 0xffffffff &&
        callIdLength > 0 &&
        callIdLength <= maxGroupCallIdBytes &&
        RegExp(r'^[0-9a-f]{24}$').hasMatch(nonce) &&
        sentAtMs > 0 &&
        type != GroupCallSignalType.unknown &&
        mediaValid &&
        (signature.isEmpty || signature.length == 64) &&
        (authorPubKey.isEmpty || authorPubKey.length == 32);
  }

  Map<String, dynamic> _unsignedJson() => {
    'v': protocolVersion,
    'g': groupId.hex,
    if (channelId != null) 'h': channelId!.hex,
    if (channelEpoch != null) 'ce': channelEpoch,
    'c': callId,
    'a': author.hex,
    'e': membershipEpoch,
    'k': type.index,
    if (media != null) 'm': media!.toJson(),
    if (reason != null) 'r': reason!.index,
    'ts': sentAtMs,
    'n': nonce,
  };

  Uint8List canonicalBytes() => Uint8List.fromList([
    ...utf8.encode('xveil.group-call.signal.v$protocolVersion\u0000'),
    ...utf8.encode(jsonEncode(_unsignedJson())),
  ]);

  Map<String, dynamic> toJson() => {
    ..._unsignedJson(),
    'sig': base64Encode(signature),
    'pk': base64Encode(authorPubKey),
  };

  String encode() => jsonEncode(toJson());

  GroupCallSignal withSignature(Uint8List nextSignature, Uint8List publicKey) =>
      GroupCallSignal(
        groupId: groupId,
        channelId: channelId,
        channelEpoch: channelEpoch,
        callId: callId,
        author: author,
        membershipEpoch: membershipEpoch,
        type: type,
        media: media,
        reason: reason,
        sentAtMs: sentAtMs,
        nonce: nonce,
        protocolVersion: protocolVersion,
        signature: Uint8List.fromList(nextSignature),
        authorPubKey: Uint8List.fromList(publicKey),
      );

  static GroupCallSignal? tryDecode(Object? encoded) {
    try {
      final Object? value = encoded is String ? jsonDecode(encoded) : encoded;
      if (value is! Map) return null;
      final json = value.cast<String, dynamic>();
      final mediaJson = json['m'];
      final signal = GroupCallSignal(
        groupId: NodeId.fromHex(json['g'] as String),
        channelId: json['h'] is String
            ? NodeId.fromHex(json['h'] as String)
            : null,
        channelEpoch: json['ce'] as int?,
        callId: json['c'] as String,
        author: NodeId.fromHex(json['a'] as String),
        membershipEpoch: (json['e'] as num).toInt(),
        type: _enumFromIndex(
          GroupCallSignalType.values,
          json['k'],
          GroupCallSignalType.unknown,
        ),
        media: mediaJson == null
            ? null
            : CallMedia.fromJson((mediaJson as Map).cast<String, dynamic>()),
        reason: json['r'] == null
            ? null
            : _enumFromIndex(
                CallEndReason.values,
                json['r'],
                CallEndReason.unknown,
              ),
        sentAtMs: (json['ts'] as num).toInt(),
        nonce: json['n'] as String,
        protocolVersion: (json['v'] as num?)?.toInt() ?? 0,
        signature: Uint8List.fromList(base64Decode(json['sig'] as String)),
        authorPubKey: Uint8List.fromList(base64Decode(json['pk'] as String)),
      );
      if (!signal.isStructurallyValid ||
          signal.signature.length != 64 ||
          signal.authorPubKey.length != 32) {
        return null;
      }
      return signal;
    } catch (_) {
      return null;
    }
  }
}

/// Wire-visible routing shell. Only gid+epoch are visible; the signed signal
/// (including call id, action and media flags) is encrypted with the group
/// epoch key. The authenticated transport source is also bound in AEAD AAD.
class GroupCallWireFrame {
  GroupCallWireFrame({
    required this.groupId,
    this.channelId,
    this.membershipEpoch,
    this.channelEpoch,
    required this.payload,
  });

  final NodeId groupId;
  final NodeId? channelId;
  final int? membershipEpoch;
  final int? channelEpoch;
  final GroupEncryptedPayload payload;

  bool get isMembershipEncrypted =>
      channelId == null && channelEpoch == null && membershipEpoch != null;

  bool get isChannelEncrypted =>
      channelId != null && channelEpoch != null && membershipEpoch == null;

  bool get isStructurallyValid =>
      ((isMembershipEncrypted &&
              membershipEpoch! > 0 &&
              membershipEpoch! <= 0xffffffff) ||
          (isChannelEncrypted &&
              channelEpoch! > 0 &&
              channelEpoch! <= 0xffffffff)) &&
      payload.isStructurallyValid &&
      payload.cipherText.length <= maxGroupCallSignalBytes;

  Map<String, dynamic> toJson() => isChannelEncrypted
      ? {
          'v': 2,
          'g': groupId.hex,
          'h': channelId!.hex,
          'ce': channelEpoch,
          'p': payload.toJson(),
        }
      : {'v': 1, 'g': groupId.hex, 'e': membershipEpoch, 'p': payload.toJson()};

  String encode() => jsonEncode(toJson());

  static GroupCallWireFrame? tryDecode(String encoded) {
    try {
      final value = jsonDecode(encoded);
      if (value is! Map || (value['v'] != 1 && value['v'] != 2)) return null;
      final version = value['v'] as int;
      if ((version == 1 &&
              (value['e'] is! int ||
                  value.containsKey('h') ||
                  value.containsKey('ce'))) ||
          (version == 2 &&
              (value['h'] is! String ||
                  value['ce'] is! int ||
                  value.containsKey('e')))) {
        return null;
      }
      final payload = GroupEncryptedPayload.fromJson(value['p']);
      if (payload == null) return null;
      final frame = GroupCallWireFrame(
        groupId: NodeId.fromHex(value['g'] as String),
        channelId: version == 2 ? NodeId.fromHex(value['h'] as String) : null,
        membershipEpoch: version == 1 ? value['e'] as int : null,
        channelEpoch: version == 2 ? value['ce'] as int : null,
        payload: payload,
      );
      return frame.isStructurallyValid ? frame : null;
    } catch (_) {
      return null;
    }
  }
}

enum GroupCallStatus { ringing, connecting, active, ended }

class GroupCallParticipant {
  const GroupCallParticipant({
    required this.nodeId,
    required this.media,
    required this.joinedAt,
    required this.lastSeenAt,
    this.mediaUpdatedAtMs = 0,
  });

  final NodeId nodeId;
  final CallMedia media;
  final DateTime joinedAt;
  final DateTime lastSeenAt;

  /// Sender timestamp of the newest posture-bearing signal we folded.
  ///
  /// Heartbeats and renegotiations may take different overlay paths. Keeping
  /// this separate from receive-time liveness prevents an older delayed frame
  /// from restoring a camera or microphone posture that the sender already
  /// changed.
  final int mediaUpdatedAtMs;

  GroupCallParticipant copyWith({
    CallMedia? media,
    DateTime? lastSeenAt,
    int? mediaUpdatedAtMs,
  }) => GroupCallParticipant(
    nodeId: nodeId,
    media: media ?? this.media,
    joinedAt: joinedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    mediaUpdatedAtMs: mediaUpdatedAtMs ?? this.mediaUpdatedAtMs,
  );
}

/// Local projection of one ephemeral group-call room. Only one room may own
/// the device media stack at a time, mirroring the existing 1:1 call slot.
class GroupCall {
  GroupCall({
    required this.groupId,
    this.channelId,
    this.channelEpoch,
    required this.callId,
    required this.initiator,
    required this.membershipEpoch,
    required this.media,
    required this.status,
    required this.startedAt,
    required this.participants,
    this.joinedAt,
    this.endedAt,
    this.endReason,
    this.micOn = true,
    this.cameraOn = true,
    this.screenOn = false,
  });

  final NodeId groupId;

  /// Voice-channel scope for a Space session; null for a plain group room.
  final NodeId? channelId;

  /// Current restricted-channel key epoch, null for open/plain rooms.
  final int? channelEpoch;
  final String callId;
  final NodeId initiator;
  final int membershipEpoch;
  final CallMedia media;
  final GroupCallStatus status;
  final DateTime startedAt;
  final DateTime? joinedAt;
  final DateTime? endedAt;
  final CallEndReason? endReason;
  final Map<String, GroupCallParticipant> participants;
  final bool micOn;
  final bool cameraOn;
  final bool screenOn;

  bool get isLive => status != GroupCallStatus.ended;
  bool isJoined(NodeId nodeId) => participants.containsKey(nodeId.hex);

  GroupCall copyWith({
    int? membershipEpoch,
    int? channelEpoch,
    CallMedia? media,
    GroupCallStatus? status,
    DateTime? joinedAt,
    DateTime? endedAt,
    CallEndReason? endReason,
    Map<String, GroupCallParticipant>? participants,
    bool? micOn,
    bool? cameraOn,
    bool? screenOn,
  }) => GroupCall(
    groupId: groupId,
    channelId: channelId,
    channelEpoch: channelEpoch ?? this.channelEpoch,
    callId: callId,
    initiator: initiator,
    membershipEpoch: membershipEpoch ?? this.membershipEpoch,
    media: media ?? this.media,
    status: status ?? this.status,
    startedAt: startedAt,
    joinedAt: joinedAt ?? this.joinedAt,
    endedAt: endedAt ?? this.endedAt,
    endReason: endReason ?? this.endReason,
    participants: participants ?? this.participants,
    micOn: micOn ?? this.micOn,
    cameraOn: cameraOn ?? this.cameraOn,
    screenOn: screenOn ?? this.screenOn,
  );
}
