import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'group_epoch.dart';
import 'group_payload.dart';

enum SpaceChannelKind {
  text,
  voice,
  category;

  static SpaceChannelKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

enum SpaceChannelHistory {
  fromJoin,
  full,
  since;

  static SpaceChannelHistory? fromName(String? value) {
    for (final policy in values) {
      if (policy.name == value) return policy;
    }
    return null;
  }
}

/// Who receives the channel control record and its independent epoch key.
///
/// [space] keeps the legacy behaviour: every active Space member sees the
/// metadata and content is protected by the Space membership epoch. The other
/// modes are never serialized as clear control-log channel payloads; their
/// complete [SpaceChannel] value lives inside [SpaceChannelControlEnvelope].
enum SpaceChannelAccess {
  space,
  restricted,
  secret;

  static SpaceChannelAccess? fromName(String? value) {
    for (final access in values) {
      if (access.name == value) return access;
    }
    return null;
  }
}

/// A signed child of one Space. Instances only become authoritative through a
/// valid create/update control entry; this value has no independent store.
class SpaceChannel {
  const SpaceChannel({
    required this.spaceId,
    required this.channelId,
    required this.kind,
    required this.name,
    required this.description,
    required this.position,
    required this.isDefault,
    required this.archived,
    required this.history,
    required this.createdBy,
    required this.createdAtMs,
    this.categoryId,
    this.historySinceMs,
    this.access = SpaceChannelAccess.space,
  });

  final NodeId spaceId;
  final NodeId channelId;
  final SpaceChannelKind kind;
  final String name;
  final String description;
  final NodeId? categoryId;
  final int position;
  final bool isDefault;
  final bool archived;
  final SpaceChannelHistory history;
  final int? historySinceMs;
  final NodeId createdBy;
  final int createdAtMs;
  final SpaceChannelAccess access;

  bool get isValid {
    if (name.trim().isEmpty || name.length > 100 || description.length > 1024) {
      return false;
    }
    if (position < -1000000 || position > 1000000 || createdAtMs < 0) {
      return false;
    }
    if (categoryId == channelId) return false;
    if (kind == SpaceChannelKind.category &&
        (categoryId != null || isDefault)) {
      return false;
    }
    if (kind == SpaceChannelKind.voice && isDefault) return false;
    if (history == SpaceChannelHistory.since) {
      if (historySinceMs == null || historySinceMs! < 0) return false;
    } else if (historySinceMs != null) {
      return false;
    }
    return true;
  }

  bool sameIdentity(SpaceChannel other) =>
      spaceId == other.spaceId &&
      channelId == other.channelId &&
      kind == other.kind &&
      access == other.access &&
      createdBy == other.createdBy &&
      createdAtMs == other.createdAtMs;

  SpaceChannel copyWith({
    String? name,
    String? description,
    NodeId? categoryId,
    bool clearCategory = false,
    int? position,
    bool? isDefault,
    bool? archived,
    SpaceChannelHistory? history,
    int? historySinceMs,
    bool clearHistorySince = false,
  }) => SpaceChannel(
    spaceId: spaceId,
    channelId: channelId,
    kind: kind,
    name: name ?? this.name,
    description: description ?? this.description,
    categoryId: clearCategory ? null : categoryId ?? this.categoryId,
    position: position ?? this.position,
    isDefault: isDefault ?? this.isDefault,
    archived: archived ?? this.archived,
    history: history ?? this.history,
    historySinceMs: clearHistorySince
        ? null
        : historySinceMs ?? this.historySinceMs,
    createdBy: createdBy,
    createdAtMs: createdAtMs,
    access: access,
  );

  Map<String, dynamic> toJson() => {
    'v': access == SpaceChannelAccess.space ? 1 : 2,
    'sid': spaceId.hex,
    'cid': channelId.hex,
    'kind': kind.name,
    'name': name,
    'desc': description,
    if (categoryId != null) 'category': categoryId!.hex,
    'position': position,
    'default': isDefault,
    'archived': archived,
    'history': history.name,
    if (historySinceMs != null) 'historySince': historySinceMs,
    'creator': createdBy.hex,
    'createdAt': createdAtMs,
    if (access != SpaceChannelAccess.space) 'access': access.name,
  };

  static SpaceChannel? fromJson(Object? value) {
    if (value is! Map || (value['v'] != 1 && value['v'] != 2)) return null;
    final version = value['v'] as int;
    final sid = value['sid'];
    final cid = value['cid'];
    final rawKind = value['kind'];
    final kind = rawKind is String ? SpaceChannelKind.fromName(rawKind) : null;
    final name = value['name'];
    final description = value['desc'];
    final position = value['position'];
    final isDefault = value['default'];
    final archived = value['archived'];
    final rawHistory = value['history'];
    final history = rawHistory is String
        ? SpaceChannelHistory.fromName(rawHistory)
        : null;
    final creator = value['creator'];
    final createdAt = value['createdAt'];
    final access = version == 1
        ? SpaceChannelAccess.space
        : SpaceChannelAccess.fromName(value['access'] as String?);
    if (sid is! String ||
        cid is! String ||
        kind == null ||
        name is! String ||
        description is! String ||
        position is! int ||
        isDefault is! bool ||
        archived is! bool ||
        history == null ||
        creator is! String ||
        createdAt is! int ||
        access == null ||
        (version == 2 && access == SpaceChannelAccess.space)) {
      return null;
    }
    final rawSince = value['historySince'];
    if (rawSince != null && rawSince is! int) return null;
    final rawCategory = value['category'];
    if (rawCategory != null && rawCategory is! String) return null;
    try {
      final channel = SpaceChannel(
        spaceId: NodeId.fromHex(sid),
        channelId: NodeId.fromHex(cid),
        kind: kind,
        name: name,
        description: description,
        categoryId: rawCategory is String ? NodeId.fromHex(rawCategory) : null,
        position: position,
        isDefault: isDefault,
        archived: archived,
        history: history,
        historySinceMs: rawSince as int?,
        createdBy: NodeId.fromHex(creator),
        createdAtMs: createdAt,
        access: access,
      );
      return channel.isValid ? channel : null;
    } catch (_) {
      return null;
    }
  }
}

const int maxSpaceChannelRecipientCount = 4096;

/// Clear channel metadata and ACL. This value exists only in memory around an
/// authenticated decrypt/encrypt operation; wire snapshots carry only the
/// [SpaceChannelControlEnvelope] ciphertext and one recipient-specific sealed
/// key record.
class SpaceChannelControlCleartext {
  SpaceChannelControlCleartext({
    required this.channel,
    required Iterable<NodeId> recipients,
  }) : recipients = List.unmodifiable(recipients);

  final SpaceChannel channel;
  final List<NodeId> recipients;

  bool get isStructurallyValid {
    if (!channel.isValid || channel.access == SpaceChannelAccess.space) {
      return false;
    }
    if (recipients.isEmpty ||
        recipients.length > maxSpaceChannelRecipientCount) {
      return false;
    }
    final ordered = recipients.map((recipient) => recipient.hex).toList();
    final sorted = [...ordered]..sort();
    return ordered.toSet().length == ordered.length &&
        _sameStrings(ordered, sorted);
  }

  Uint8List encode() {
    if (!isStructurallyValid) {
      throw const FormatException('invalid channel control cleartext');
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'channel': channel.toJson(),
          'recipients': [for (final recipient in recipients) recipient.hex],
        }),
      ),
    );
  }

  static SpaceChannelControlCleartext? decode(Uint8List bytes) {
    if (bytes.length > maxGroupEncryptedPayloadBytes) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (value is! Map || value['v'] != 1 || value['recipients'] is! List) {
        return null;
      }
      final channel = SpaceChannel.fromJson(value['channel']);
      final rawRecipients = value['recipients'] as List;
      if (channel == null || rawRecipients.any((entry) => entry is! String)) {
        return null;
      }
      final cleartext = SpaceChannelControlCleartext(
        channel: channel,
        recipients: rawRecipients
            .cast<String>()
            .map(NodeId.fromHex)
            .toList(growable: false),
      );
      return cleartext.isStructurallyValid ? cleartext : null;
    } catch (_) {
      return null;
    }
  }
}

/// Opaque signed child-control payload for a restricted/secret channel.
///
/// The descriptor uses `channelId` as its cryptographic scope id, so its key
/// commitment and Merkle recipient root cannot be replayed into another
/// channel. The enclosing [ControlEntry] additionally binds it to [spaceId].
class SpaceChannelControlEnvelope {
  const SpaceChannelControlEnvelope({
    required this.spaceId,
    required this.channelId,
    required this.channelEpoch,
    required this.keyDescriptor,
    required this.encryptedControl,
  });

  final NodeId spaceId;
  final NodeId channelId;
  final int channelEpoch;
  final GroupEpochDescriptor keyDescriptor;
  final GroupEncryptedPayload encryptedControl;

  bool get isStructurallyValid =>
      channelEpoch > 0 &&
      channelEpoch <= 0xffffffff &&
      keyDescriptor.groupId == channelId &&
      keyDescriptor.epoch == channelEpoch &&
      keyDescriptor.recipientCount <= maxSpaceChannelRecipientCount &&
      encryptedControl.isStructurallyValid;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'sid': spaceId.hex,
    'cid': channelId.hex,
    'epoch': channelEpoch,
    'key': keyDescriptor.toJson(),
    'enc': encryptedControl.toJson(),
  };

  static SpaceChannelControlEnvelope? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final sid = value['sid'];
    final cid = value['cid'];
    final epoch = value['epoch'];
    final descriptor = GroupEpochDescriptor.fromJson(value['key']);
    final encrypted = GroupEncryptedPayload.fromJson(value['enc']);
    if (sid is! String ||
        cid is! String ||
        epoch is! int ||
        descriptor == null ||
        encrypted == null) {
      return null;
    }
    try {
      final envelope = SpaceChannelControlEnvelope(
        spaceId: NodeId.fromHex(sid),
        channelId: NodeId.fromHex(cid),
        channelEpoch: epoch,
        keyDescriptor: descriptor,
        encryptedControl: encrypted,
      );
      return envelope.isStructurallyValid ? envelope : null;
    } catch (_) {
      return null;
    }
  }
}

/// Opaque moderation evidence for one restricted channel.
///
/// The channel id and epoch are already public in the restricted-channel V1
/// control shape. The target, reason and referenced message remain encrypted
/// under that channel epoch key and are authenticated by the enclosing signed
/// [ControlEntry].
class SpaceChannelModerationEnvelope {
  const SpaceChannelModerationEnvelope({
    required this.spaceId,
    required this.channelId,
    required this.channelEpoch,
    required this.encryptedAction,
  });

  final NodeId spaceId;
  final NodeId channelId;
  final int channelEpoch;
  final GroupEncryptedPayload encryptedAction;

  bool get isStructurallyValid =>
      channelEpoch > 0 &&
      channelEpoch <= 0xffffffff &&
      encryptedAction.isStructurallyValid;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'sid': spaceId.hex,
    'cid': channelId.hex,
    'epoch': channelEpoch,
    'enc': encryptedAction.toJson(),
  };

  static SpaceChannelModerationEnvelope? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final sid = value['sid'];
    final cid = value['cid'];
    final epoch = value['epoch'];
    final encrypted = GroupEncryptedPayload.fromJson(value['enc']);
    if (sid is! String ||
        cid is! String ||
        epoch is! int ||
        encrypted == null) {
      return null;
    }
    try {
      final envelope = SpaceChannelModerationEnvelope(
        spaceId: NodeId.fromHex(sid),
        channelId: NodeId.fromHex(cid),
        channelEpoch: epoch,
        encryptedAction: encrypted,
      );
      return envelope.isStructurallyValid ? envelope : null;
    } catch (_) {
      return null;
    }
  }
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Stable channel for legacy group-level messages. It is public protocol
/// derivation, not a secret or a content hash.
NodeId defaultSpaceChannelId(NodeId spaceId) {
  final bytes = utf8.encode('xveil.space.default-channel.v1:${spaceId.hex}');
  return NodeId(Uint8List.fromList(crypto.sha256.convert(bytes).bytes));
}

/// Stable presentation order: root channels/categories by signed position,
/// followed immediately by each category's direct children. The service
/// rejects nested categories, but legacy/corrupt orphan children are retained
/// as roots instead of disappearing from the management UI.
List<SpaceChannel> orderSpaceChannelsForDisplay(Iterable<SpaceChannel> values) {
  final channels = values.toList(growable: false);
  int compare(SpaceChannel left, SpaceChannel right) {
    final position = left.position.compareTo(right.position);
    if (position != 0) return position;
    return left.channelId.hex.compareTo(right.channelId.hex);
  }

  final categoryIds = {
    for (final channel in channels)
      if (channel.kind == SpaceChannelKind.category) channel.channelId.hex,
  };
  final roots =
      channels
          .where(
            (channel) =>
                channel.categoryId == null ||
                !categoryIds.contains(channel.categoryId!.hex),
          )
          .toList()
        ..sort(compare);
  final children = <String, List<SpaceChannel>>{};
  for (final channel in channels) {
    final category = channel.categoryId;
    if (category == null || !categoryIds.contains(category.hex)) continue;
    children.putIfAbsent(category.hex, () => []).add(channel);
  }
  for (final list in children.values) {
    list.sort(compare);
  }
  return List.unmodifiable([
    for (final root in roots) ...[
      root,
      if (root.kind == SpaceChannelKind.category)
        ...?children[root.channelId.hex],
    ],
  ]);
}

/// A gap-preserving default position for a newly created sibling.
int nextSpaceChannelPosition(
  Iterable<SpaceChannel> values, {
  NodeId? categoryId,
}) {
  var maximum = -100;
  for (final channel in values) {
    if (channel.categoryId == categoryId && channel.position > maximum) {
      maximum = channel.position;
    }
  }
  return (maximum + 100).clamp(-1000000, 1000000);
}
