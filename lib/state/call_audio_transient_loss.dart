/// Debounces fresh concealment/catch-up witnesses at the endpoint.
/// Callers consume native report counters before passing an event here.
class CallAudioTransientLoss {
  static const repeatWindow = Duration(seconds: 6);
  static const growthHold = Duration(seconds: 3);
  final List<DateTime> _events = [];
  DateTime? _lastAt;
  bool holdingGrowth = false;

  /// Only a new event can confirm repetition. Cached reports and faster
  /// polling neither add events nor advance a sample-count-based timeout.
  bool observe(bool event, {DateTime? sampledAt}) {
    final now = sampledAt ?? DateTime.now();
    if (_lastAt != null && now.isBefore(_lastAt!)) reset();
    _lastAt = now;
    _events.removeWhere((at) => now.difference(at) > repeatWindow);
    if (event) {
      _events.add(now);
      if (_events.length > 2) _events.removeAt(0);
    }
    holdingGrowth =
        _events.isNotEmpty && now.difference(_events.last) < growthHold;
    return event && _events.length >= 2;
  }

  void reset() {
    _events.clear();
    _lastAt = null;
    holdingGrowth = false;
  }
}
