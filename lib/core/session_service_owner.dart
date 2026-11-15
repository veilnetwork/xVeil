import 'dart:async';

/// Provider disposal starts cleanup; the session boundary must also join it.
/// Retired providers remain owned until their cleanup succeeds or drain reports
/// its error, even if Riverpod has already installed their replacement.
class SessionServiceOwner {
  final Set<Future<void> Function()> _closers = {};

  Future<void> Function() register(Future<void> Function() cleanup) {
    Future<void>? closing;
    late Future<void> Function() close;
    close = () => closing ??= Future<void>.sync(cleanup).then((_) {
      _closers.remove(close);
    });
    _closers.add(close);
    return close;
  }

  Future<void> drain() async {
    while (_closers.isNotEmpty) {
      final batch = _closers.toList();
      try {
        // Future.wait waits for every cleanup even when one fails.
        await Future.wait([for (final close in batch) close()]);
      } finally {
        _closers.removeAll(batch);
      }
    }
  }
}
