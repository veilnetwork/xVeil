/// Compare identity-wide reaction state without hiding duplicate device slots.
/// Every participant in the stand is known; a consistently wrong extra actor
/// on all replicas must not turn into a successful convergence observation.
Map<String, dynamic> normalizeDeviceReactions(
  Map<String, dynamic> raw, {
  required Map<String, String> deviceIdentities,
}) {
  if (deviceIdentities.isEmpty) {
    throw ArgumentError('reaction oracle requires known device identities');
  }
  final identities = deviceIdentities.values.toSet();
  final normalized = <String, dynamic>{};
  for (final entry in raw.entries) {
    final actor = deviceIdentities[entry.key] ?? entry.key;
    if (!identities.contains(actor)) {
      throw StateError('reaction oracle observed an unknown actor');
    }
    if (normalized.containsKey(actor)) {
      throw StateError('reaction oracle observed duplicate identity slots');
    }
    normalized[actor] = entry.value;
  }
  return normalized;
}
