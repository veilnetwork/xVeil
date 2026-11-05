import '../core/ids.dart';
import 'device_sync.dart';
import 'disappearing_messages.dart';
import 'chat.dart';

/// Portable preferences only; consent and per-device P2P are separate.
Map<String, Object?> contactPrefsPayload(Contact c) => {
  'name': c.name,
  'mutedMs': c.mutedUntil?.millisecondsSinceEpoch,
  'muteMode': c.notificationMuteMode.name,
  'pin': c.pinned,
  'arc': c.archived,
  'ret': c.retentionDays,
  'apd': c.allowPeerDelete,
  // A decision about MY history is mine on every device I own.
  'clp': c.clearPolicy.name,
  // The retention policy travels WITH the preferences, carrying its own stamp
  // and setter so the sibling can run the same last-writer-wins rule a peer's
  // announcement goes through.
  'dtl': c.disappearingTtlSeconds,
  'dsa': c.disappearingSetAtMs,
  'dsb': c.disappearingSetBy,
  'har': c.hideAfterReadSeconds,
};

/// The policy has its own clock and convergence slot. A later alias snapshot
/// carrying an older policy must not compact away the last policy evidence.
DeviceSyncEvent? contactPolicyEvent(NodeId peer, Map<String, Object?> payload) {
  final policy = DisappearingSetting.fromMirrorFields(payload);
  // Zero is the unconfigured default, not a decision to turn a window off.
  // Real off decisions have their own positive revision too.
  if (policy == null || policy.setAtMs == 0) return null;
  return DeviceSyncEvent(
    kind: DeviceSyncKind.contactUp,
    key: 'd:${peer.hex}',
    tsMs: policy.setAtMs,
    payload: {
      'dtl': policy.ttlSeconds,
      'dsa': policy.setAtMs,
      'dsb': policy.setBy,
      'har': policy.hideAfterReadSeconds,
    },
  );
}

DisappearingSetting? contactPolicyFromEvent(
  DeviceSyncEvent event, {
  DateTime? now,
}) {
  if (event.kind != DeviceSyncKind.contactUp ||
      !RegExp(r'^d:[0-9a-f]{64}$').hasMatch(event.key)) {
    return null;
  }
  final policy = DisappearingSetting.fromMirrorJson(event.payload, now: now);
  return policy != null && policy.setAtMs == event.tsMs ? policy : null;
}
