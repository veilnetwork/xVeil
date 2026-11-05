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
