/// Interpret a measured receiver delay without charging its jitter reserve as
/// extra congestion. This never changes raw telemetry or buffer growth trends.
class CallAudioPlayoutReserve {
  // Matches the native NetEq policy; unknown/larger targets stay conservative.
  static const maximumTargetMs = 400;
  static const nominalTargetMs = 80;
  // A 60-ms packet and two render blocks can straddle a current snapshot.
  static const arrivalToleranceMs = 80;
  static const maximumCreditMs = maximumTargetMs - nominalTargetMs;

  static bool _valid(int? value) =>
      value != null && value >= 0 && value <= 60000;

  /// Only a current, coherent target/delay pair can establish a reserve. The
  /// caller enforces native/peer freshness; a requested, unfilled target alone
  /// is not evidence of healthy audio or an available producer budget.
  static int creditMs(int? currentDelayMs, int? targetDelayMs) {
    if (!_valid(currentDelayMs) ||
        !_valid(targetDelayMs) ||
        targetDelayMs! > maximumTargetMs ||
        currentDelayMs! + arrivalToleranceMs < targetDelayMs) {
      return 0;
    }
    return (targetDelayMs - nominalTargetMs).clamp(0, maximumCreditMs);
  }

  static int? pressureDelayMs(int? currentDelayMs, int creditMs) {
    if (!_valid(currentDelayMs)) return null;
    final credit = creditMs >= 0 && creditMs <= maximumCreditMs ? creditMs : 0;
    return (currentDelayMs! - credit).clamp(0, 60000);
  }

  static bool targetAllowsGrowth(
    int? targetDelayMs,
    int creditMs, {
    required int recoverMs,
  }) =>
      targetDelayMs == null ||
      (_valid(targetDelayMs) &&
          (targetDelayMs < recoverMs ||
              (targetDelayMs <= maximumTargetMs &&
                  creditMs > 0 &&
                  creditMs <= maximumCreditMs)));
}
