import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';

const _spaceRecommendationMessagePrefix = 'xveil:space-recommendation:v1:';

/// True for the reserved durable representation, including malformed cards.
///
/// Callers use this stricter prefix check at ordinary-message mutation
/// boundaries so a typed card cannot be forged, edited or forwarded by
/// smuggling its storage representation through the plain-text API.
bool isSpaceRecommendationMessageBody(String body) =>
    body.startsWith(_spaceRecommendationMessagePrefix);

enum SpaceRecommendationShareResult {
  sent,
  invalidCampaign,
  notAllowed,
  invalidRecipient,
  alreadyMember,
  duplicate,
  rateLimited,
  failed,
}

enum SpaceRecommendationRevokeResult {
  revoked,
  notFound,
  alreadyRevoked,
  unavailable,
  failed,
}

class SpaceRecommendationShareAudit {
  const SpaceRecommendationShareAudit({
    required this.campaignId,
    required this.spaceId,
    required this.recipient,
    required this.sentAtMs,
    this.messageId,
    this.revokedAtMs,
  });

  final String campaignId;
  final NodeId spaceId;
  final NodeId recipient;
  final int sentAtMs;
  final String? messageId;
  final int? revokedAtMs;

  bool get canRevoke => messageId != null && revokedAtMs == null;

  String get stableId =>
      messageId ?? '${spaceId.hex}:$campaignId:${recipient.hex}:$sentAtMs';

  SpaceRecommendationShareAudit revokedAt(int timestampMs) =>
      SpaceRecommendationShareAudit(
        campaignId: campaignId,
        spaceId: spaceId,
        recipient: recipient,
        sentAtMs: sentAtMs,
        messageId: messageId,
        revokedAtMs: timestampMs,
      );

  Map<String, dynamic> toJson() => {
    'campaign': campaignId,
    'space': spaceId.hex,
    'recipient': recipient.hex,
    'sentAt': sentAtMs,
    if (messageId != null) 'message': messageId,
    if (revokedAtMs != null) 'revokedAt': revokedAtMs,
  };

  static SpaceRecommendationShareAudit? fromJson(Object? value) {
    if (value is! Map ||
        value['campaign'] is! String ||
        value['space'] is! String ||
        value['recipient'] is! String ||
        value['sentAt'] is! int ||
        (value.containsKey('message') && value['message'] is! String) ||
        (value.containsKey('revokedAt') && value['revokedAt'] is! int)) {
      return null;
    }
    try {
      final record = SpaceRecommendationShareAudit(
        campaignId: value['campaign'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        recipient: NodeId.fromHex(value['recipient'] as String),
        sentAtMs: value['sentAt'] as int,
        messageId: value['message'] as String?,
        revokedAtMs: value['revokedAt'] as int?,
      );
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(record.campaignId) ||
          record.sentAtMs < 0 ||
          (record.messageId != null &&
              (record.messageId!.isEmpty || record.messageId!.length > 256)) ||
          (record.revokedAtMs != null &&
              record.revokedAtMs! < record.sentAtMs)) {
        return null;
      }
      return record;
    } catch (_) {
      return null;
    }
  }
}

/// One complete, signed Space-wide recommendation policy.
///
/// V1 deliberately controls only whether active campaigns may be created and
/// explicitly shared. The fixed anti-spam ceilings remain a non-configurable
/// client safety boundary, so an administrator can never weaken them through
/// a signed Space setting.
final class SpaceRecommendationPolicy {
  const SpaceRecommendationPolicy({
    required this.spaceId,
    required this.revision,
    required this.previousPolicyHash,
    required this.changedBy,
    required this.changedAtMs,
    required this.enabled,
  });

  final NodeId spaceId;
  final int revision;
  final String previousPolicyHash;
  final NodeId changedBy;
  final int changedAtMs;
  final bool enabled;

  bool get isStructurallyValid =>
      revision >= 1 &&
      changedAtMs >= 0 &&
      (revision == 1
          ? previousPolicyHash.isEmpty
          : RegExp(r'^[0-9a-f]{64}$').hasMatch(previousPolicyHash));

  Uint8List canonicalBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  String get policyHash => crypto.sha256.convert(canonicalBytes()).toString();

  Map<String, dynamic> toJson() => {
    'v': 1,
    'space': spaceId.hex,
    'revision': revision,
    'previous': previousPolicyHash,
    'changedBy': changedBy.hex,
    'changedAt': changedAtMs,
    'enabled': enabled,
  };

  static SpaceRecommendationPolicy? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['space'] is! String ||
        value['revision'] is! int ||
        value['previous'] is! String ||
        value['changedBy'] is! String ||
        value['changedAt'] is! int ||
        value['enabled'] is! bool) {
      return null;
    }
    try {
      final policy = SpaceRecommendationPolicy(
        spaceId: NodeId.fromHex(value['space'] as String),
        revision: value['revision'] as int,
        previousPolicyHash: value['previous'] as String,
        changedBy: NodeId.fromHex(value['changedBy'] as String),
        changedAtMs: value['changedAt'] as int,
        enabled: value['enabled'] as bool,
      );
      return policy.isStructurallyValid ? policy : null;
    } catch (_) {
      return null;
    }
  }
}

enum SpaceRecommendationRecipientMode {
  acceptedContacts,
  blockAll;

  static SpaceRecommendationRecipientMode? fromName(String? value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

/// Identity-local recipient posture. This is intentionally not Space
/// authority and never travels on the wire, preventing a preference oracle.
final class SpaceRecommendationRecipientPolicy {
  const SpaceRecommendationRecipientPolicy({
    this.mode = SpaceRecommendationRecipientMode.acceptedContacts,
  });

  final SpaceRecommendationRecipientMode mode;

  bool get acceptsCards =>
      mode == SpaceRecommendationRecipientMode.acceptedContacts;

  Map<String, dynamic> toJson() => {'v': 1, 'mode': mode.name};

  static SpaceRecommendationRecipientPolicy? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1 || value['mode'] is! String) {
      return null;
    }
    final mode = SpaceRecommendationRecipientMode.fromName(
      value['mode'] as String,
    );
    return mode == null ? null : SpaceRecommendationRecipientPolicy(mode: mode);
  }
}

/// A signed Space-wide recommendation campaign.
///
/// The campaign is authored by an owner/admin and replicated in the Space
/// control log. Ordinary members may then distribute its public card through
/// an explicit 1:1-chat action without gaining membership-management powers.
class SpaceRecommendationCampaign {
  const SpaceRecommendationCampaign({
    required this.campaignId,
    required this.spaceId,
    required this.createdBy,
    required this.text,
    required this.joinCode,
    required this.createdAtMs,
    required this.changedAtMs,
    required this.active,
  });

  final String campaignId;
  final NodeId spaceId;
  final NodeId createdBy;
  final String text;
  final String joinCode;
  final int createdAtMs;
  final int changedAtMs;
  final bool active;

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(campaignId) &&
      text == text.trim() &&
      text.isNotEmpty &&
      text.length <= 1000 &&
      createdAtMs >= 0 &&
      changedAtMs >= createdAtMs &&
      ((!active && joinCode.isEmpty) ||
          (active && joinCode.isNotEmpty && joinCode.length <= 4096));

  Map<String, dynamic> toJson() => {
    'id': campaignId,
    'space': spaceId.hex,
    'creator': createdBy.hex,
    'text': text,
    'join': joinCode,
    'created': createdAtMs,
    'changed': changedAtMs,
    'active': active,
  };

  static SpaceRecommendationCampaign? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['space'] is! String ||
        value['creator'] is! String ||
        value['text'] is! String ||
        value['join'] is! String ||
        value['created'] is! int ||
        value['changed'] is! int ||
        value['active'] is! bool) {
      return null;
    }
    try {
      final campaign = SpaceRecommendationCampaign(
        campaignId: value['id'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        createdBy: NodeId.fromHex(value['creator'] as String),
        text: value['text'] as String,
        joinCode: value['join'] as String,
        createdAtMs: value['created'] as int,
        changedAtMs: value['changed'] as int,
        active: value['active'] as bool,
      );
      return campaign.isStructurallyValid ? campaign : null;
    } catch (_) {
      return null;
    }
  }
}

/// Typed card carried in an explicitly selected 1:1 chat.
class SpaceRecommendationCard {
  const SpaceRecommendationCard({
    required this.campaignId,
    required this.spaceId,
    required this.name,
    required this.description,
    required this.text,
    required this.joinCode,
  });

  final String campaignId;
  final NodeId spaceId;
  final String name;
  final String description;
  final String text;
  final String joinCode;

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(campaignId) &&
      name == name.trim() &&
      name.isNotEmpty &&
      name.length <= 160 &&
      description.length <= 4096 &&
      text == text.trim() &&
      text.isNotEmpty &&
      text.length <= 1000 &&
      joinCode.isNotEmpty &&
      joinCode.length <= 4096;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'campaign': campaignId,
    'space': spaceId.hex,
    'name': name,
    'description': description,
    'text': text,
    'join': joinCode,
  };

  static SpaceRecommendationCard? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['campaign'] is! String ||
        value['space'] is! String ||
        value['name'] is! String ||
        value['description'] is! String ||
        value['text'] is! String ||
        value['join'] is! String) {
      return null;
    }
    try {
      final card = SpaceRecommendationCard(
        campaignId: value['campaign'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        name: value['name'] as String,
        description: value['description'] as String,
        text: value['text'] as String,
        joinCode: value['join'] as String,
      );
      return card.isStructurallyValid ? card : null;
    } catch (_) {
      return null;
    }
  }
}

/// Persist a card as an ordinary event-log body while keeping it typed on the
/// wire. This lets existing deletion, ACK, retention and multi-device paths
/// keep one message model; renderers never expose the opaque body.
String encodeSpaceRecommendationMessage(SpaceRecommendationCard card) {
  if (!card.isStructurallyValid) {
    throw const FormatException('invalid Space recommendation card');
  }
  final bytes = utf8.encode(jsonEncode(card.toJson()));
  return '$_spaceRecommendationMessagePrefix${base64Url.encode(bytes).replaceAll('=', '')}';
}

SpaceRecommendationCard? parseSpaceRecommendationMessage(String body) {
  if (!isSpaceRecommendationMessageBody(body) || body.length > 16384) {
    return null;
  }
  try {
    final encoded = body.substring(_spaceRecommendationMessagePrefix.length);
    final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
    return SpaceRecommendationCard.fromJson(
      jsonDecode(utf8.decode(base64Url.decode(padded))),
    );
  } catch (_) {
    return null;
  }
}
