/// Pure sender-side link-quality ladder for live call video.
///
/// Consumes the per-second engine stats sample (remote-reported outbound loss
/// and jitter from RTCP report blocks, round-trip time, and the local sender
/// queue drop counter) and walks a fixed ladder of bitrate fractions below the
/// route profile's budget. The route profile is a hard ceiling: adaptation
/// only ever spends LESS than the negotiated route allows (the padded onion
/// budget stays authoritative), so privacy decisions are never traded for
/// quality.
///
/// Pure and synchronous — no timers, no engine handles — so the policy is unit
/// testable; the media controller owns wiring it to the 1 s stats poll.
class CallBitrateAdapter {
  CallBitrateAdapter({required this.baseBitrateKbps, required this.baseFps});

  /// Route-profile budget this call negotiated; the ladder scales below it.
  final int baseBitrateKbps;
  final int baseFps;

  /// Fractions of the base budget, best-first. The last rung also reduces fps:
  /// at that point the link is bad enough that fewer, better frames beat rate.
  static const List<double> ladder = [1.0, 0.75, 0.5, 0.3];

  /// Consecutive bad samples (~seconds) before stepping down.
  static const int degradeAfter = 2;

  /// Consecutive good samples (~seconds) before stepping back up. Recovery is
  /// deliberately much slower than degradation so a marginal link settles
  /// instead of oscillating.
  static const int recoverAfter = 12;

  int _level = 0;
  int _badStreak = 0;
  int _goodStreak = 0;
  int? _lastTxDrops;

  /// Current rung (0 = full route budget).
  int get level => _level;

  /// Target for the current rung.
  ({int maxBitrateKbps, int maxFps}) get target => (
        maxBitrateKbps: (baseBitrateKbps * ladder[_level]).round(),
        maxFps: _level == ladder.length - 1
            ? (baseFps * 2 / 3).round().clamp(5, baseFps)
            : baseFps,
      );

  /// Feed one stats sample; returns the new target when the rung changed and
  /// null otherwise. `rttMs` of 0 means "unknown yet" and is not judged.
  ({int maxBitrateKbps, int maxFps})? onSample({
    required int rttMs,
    required int txJitterMs,
    required int txLossPct,
    required int txDrops,
  }) {
    final newDrops = _lastTxDrops != null && txDrops > _lastTxDrops!;
    _lastTxDrops = txDrops;

    final bad = txLossPct >= 5 ||
        txJitterMs >= 80 ||
        (rttMs > 0 && rttMs >= 400) ||
        newDrops;
    final good = txLossPct <= 1 &&
        txJitterMs < 40 &&
        (rttMs == 0 || rttMs < 250) &&
        !newDrops;

    if (bad) {
      _goodStreak = 0;
      _badStreak++;
      if (_badStreak >= degradeAfter && _level < ladder.length - 1) {
        _badStreak = 0;
        _level++;
        return target;
      }
      return null;
    }
    _badStreak = 0;
    if (!good) {
      // Marginal sample: hold the rung, restart the recovery clock.
      _goodStreak = 0;
      return null;
    }
    _goodStreak++;
    if (_goodStreak >= recoverAfter && _level > 0) {
      _goodStreak = 0;
      _level--;
      return target;
    }
    return null;
  }
}
