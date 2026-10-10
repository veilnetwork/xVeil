import 'dart:async';

/// Bounded diagnostic observations, without committing a route or holding the
/// route-operation lock. A repair/hangup can retire the call at every await.
class CallRouteDeliveryObserver {
  bool _running = false;

  Future<Map<String, Object?>> observe({
    required int currentChannel,
    required bool Function() stillOwned,
    required Future<int?> Function() openAlternate,
    required Future<bool> Function(int) qualify,
    required void Function(int) closeAlternate,
    int samples = 20,
  }) async {
    if (samples < 1 || samples > 30) {
      throw ArgumentError.value(samples, 'samples', 'must be 1..30');
    }
    if (_running) return {'ok': false, 'reason': 'busy'};
    _running = true;
    int? alternate;
    final observations = <Map<String, Object?>>[];
    try {
      if (!stillOwned()) return {'ok': false, 'reason': 'call_changed'};
      alternate = await openAlternate();
      if (!stillOwned()) return {'ok': false, 'reason': 'call_changed'};
      if (alternate == null) {
        return {'ok': false, 'reason': 'alternate_unavailable'};
      }
      for (var sample = 0; sample < samples; sample++) {
        if (!stillOwned()) break;
        final current = await _measure(currentChannel, qualify);
        // Peer echoes are rate limited to one per 200 ms across contexts.
        // Concurrent probes would measure that limit rather than two paths.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!stillOwned()) break;
        final other = await _measure(alternate, qualify);
        if (!stillOwned()) break;
        observations.add({
          'sample': sample,
          'current': current,
          'alternate': other,
        });
        if (sample + 1 < samples) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      return {
        // Completion does not claim that either path delivered the probe.
        'ok': stillOwned() && observations.length == samples,
        'reason': stillOwned() ? 'completed' : 'call_changed',
        'samples': observations,
      };
    } catch (_) {
      return {'ok': false, 'reason': 'probe_error', 'samples': observations};
    } finally {
      try {
        if (alternate != null) closeAlternate(alternate);
      } finally {
        _running = false;
      }
    }
  }

  static Future<Map<String, Object?>> _measure(
    int channel,
    Future<bool> Function(int) qualify,
  ) async {
    final clock = Stopwatch()..start();
    final qualified = await qualify(channel);
    return {
      'qualified': qualified,
      // Includes local admission and the native status poll (10-ms cadence).
      // A failed observation is not an RTT measurement.
      'qualification_elapsed_ms': clock.elapsedMilliseconds,
    };
  }
}
