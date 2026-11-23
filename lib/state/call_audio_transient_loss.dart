/// Debounces fresh audio impairment witnesses at the endpoint.
/// Callers consume native report counters before passing an event here.
class CallAudioTransientLoss {
  static const repeatWindow = Duration(seconds: 6);
  static const growthHold = Duration(seconds: 3);
  final List<DateTime> _events = [];
  DateTime? _lastAt;
  bool holdingGrowth = false;

  /// Original fresh event behind the current hold; polls do not renew it.
  DateTime? get lastEventAt => _events.isEmpty ? null : _events.last;

  /// Only a new event can confirm repetition. Cached reports and faster
  /// polling neither add events nor extend the hold. Native receipt age
  /// accounts for delay between a report arriving and the observer's poll.
  bool observe(bool event, {DateTime? sampledAt, Duration? eventAge}) {
    final now = sampledAt ?? DateTime.now();
    if (_lastAt != null && now.isBefore(_lastAt!)) reset();
    _lastAt = now;
    _events.removeWhere((at) => now.difference(at) > repeatWindow);
    final recentEvent = event && (eventAge == null || eventAge <= repeatWindow);
    if (recentEvent) {
      _events.add(
        eventAge == null || eventAge.isNegative ? now : now.subtract(eventAge),
      );
      _events.sort();
      if (_events.length > 2) _events.removeAt(0);
    }
    holdingGrowth =
        _events.isNotEmpty && now.difference(_events.last) < growthHold;
    return recentEvent && _events.length >= 2;
  }

  void reset() {
    _events.clear();
    _lastAt = null;
    holdingGrowth = false;
  }
}
