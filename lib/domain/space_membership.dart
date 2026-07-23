import '../core/ids.dart';
import 'group.dart';

/// User-facing membership state derived from authoritative signed facts.
///
/// This is deliberately a projection, not another persisted membership table:
/// `active`, `suspended`, `left`, and `banned` come from the accepted Space
/// control-log plus its signed moderation fold. `pending` comes only from an
/// already-durable consent/join proposal while the signed grant is absent.
enum SpaceMembershipStatus { pending, active, suspended, left, banned }

enum SpaceMembershipSource {
  manifest,
  controlLog,
  moderation,
  joinRequest,
  invite,
}

class SpaceMembershipProjection {
  const SpaceMembershipProjection({
    required this.spaceId,
    required this.name,
    required this.visibility,
    required this.status,
    required this.source,
    required this.isMember,
    required this.changedAtMs,
    this.untilMs,
    this.reason,
    this.sourceId,
  });

  final NodeId spaceId;
  final String name;
  final SpaceVisibility visibility;
  final SpaceMembershipStatus status;
  final SpaceMembershipSource source;

  /// Whether the canonical control fold currently contains this identity.
  ///
  /// A timeout keeps membership but projects `suspended`; a temporary ban
  /// removes membership and also projects `suspended` until it expires.
  final bool isMember;
  final int changedAtMs;
  final int? untilMs;
  final String? reason;
  final String? sourceId;

  bool get canOpen => isMember;
}
