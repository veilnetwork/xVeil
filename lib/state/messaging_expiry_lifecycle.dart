part of 'messaging_core.dart';

/// Start cleanup immediately, including when group bindings arrive later.
/// One owned job coalesces readiness notices; teardown joins its writes.
class _MessagingExpiryLifecycle {
  _MessagingExpiryLifecycle(this.owner);
  final MessagingService owner;
  Future<void>? _work;
  bool _again = false, _closed = false;
  bool get pending => _work != null;

  /// An explicit reconnect must retain its recovery pass while startup owns
  /// the history barrier. Ordinary periodic retries keep their own cadence.
  Future<void> settle() async {
    while (_work != null) {
      await _work;
    }
  }

  void request() {
    if (_closed || owner._disposed) return;
    _again = true;
    if (_work != null) return;
    late final Future<void> work;
    work =
        Future<void>.microtask(() async {
              do {
                _again = false;
                await owner.sweepAllDisappearing();
              } while (_again && !_closed && !owner._disposed);
            })
            .catchError((Object error) {
              devLog(
                () =>
                    'xVeil[disappearing]: startup cleanup deferred '
                    '(${error.runtimeType})',
              );
            })
            .whenComplete(() {
              if (identical(_work, work)) _work = null;
              if (!_closed && !owner._disposed) {
                owner._ownHistory.nudge();
                // Only resume deferred durable controls. Ordinary message recovery
                // keeps its existing cadence (and give-up deadlines).
                unawaited(
                  owner._flushOutboxFrames().catchError((Object error) {
                    devLog(
                      () =>
                          'xVeil[disappearing]: deferred group flush failed '
                          '(${error.runtimeType})',
                    );
                  }),
                );
              }
            });
    _work = work;
    unawaited(work);
  }

  /// Defer background copies WHILE the initial local rewrite is in progress.
  /// This spends no network backoff; call/control lanes stay live.
  bool defers(OutboxFrame frame) {
    if (!pending) return false;
    try {
      final kind = WireEnvelope.decode(frame.wire).kind;
      if (kind == WireKind.groupEntry || kind == WireKind.groupEntryChunk) {
        return deferSource(frame.peerHex, frame.frameId);
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  bool deferSource(String peer, String id) {
    if (!pending) return false;
    owner._outbox._liveBackoff.remove(_MessagingOutbox._key(peer, id));
    return true;
  }

  Future<void> close() async {
    _closed = true;
    _again = false;
    await _work;
  }
}
