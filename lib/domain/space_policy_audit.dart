import '../core/ids.dart';
import 'space_access.dart';
import 'space_retention.dart';

/// A typed, immutable policy event exposed to authorized Space members.
///
/// The shared base carries only ordering and authorship. Policy payloads stay
/// in separate concrete types so adding a new policy family never turns the
/// audit into an unvalidated JSON bag.
sealed class SpacePolicyAuditEntry {
  const SpacePolicyAuditEntry({
    required this.author,
    required this.changedAtMs,
  });

  final NodeId author;
  final int changedAtMs;

  String get stableId;
}

final class SpaceAccessPolicyAuditEntry extends SpacePolicyAuditEntry {
  SpaceAccessPolicyAuditEntry(this.policy)
    : super(author: policy.changedBy, changedAtMs: policy.changedAtMs);

  final SpaceAccessPolicy policy;

  @override
  String get stableId => 'access:${policy.policyHash}';
}

final class SpaceRetentionPolicyAuditEntry extends SpacePolicyAuditEntry {
  SpaceRetentionPolicyAuditEntry(this.revision)
    : super(author: revision.author, changedAtMs: revision.activatedAtMs);

  final SpaceRetentionRevision revision;

  @override
  String get stableId =>
      'retention:${revision.author.hex}:${revision.authorSeq}';
}
