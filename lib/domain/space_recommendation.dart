import 'dart:convert';

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

class SpaceRecommendationShareAudit {
  const SpaceRecommendationShareAudit({
    required this.campaignId,
    required this.spaceId,
    required this.recipient,
    required this.sentAtMs,
  });

  final String campaignId;
  final NodeId spaceId;
  final NodeId recipient;
  final int sentAtMs;

  Map<String, dynamic> toJson() => {
    'campaign': campaignId,
    'space': spaceId.hex,
    'recipient': recipient.hex,
    'sentAt': sentAtMs,
  };

  static SpaceRecommendationShareAudit? fromJson(Object? value) {
    if (value is! Map ||
        value['campaign'] is! String ||
        value['space'] is! String ||
        value['recipient'] is! String ||
        value['sentAt'] is! int) {
      return null;
    }
    try {
      final record = SpaceRecommendationShareAudit(
        campaignId: value['campaign'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        recipient: NodeId.fromHex(value['recipient'] as String),
        sentAtMs: value['sentAt'] as int,
      );
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(record.campaignId) ||
          record.sentAtMs < 0) {
        return null;
      }
      return record;
    } catch (_) {
      return null;
    }
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
