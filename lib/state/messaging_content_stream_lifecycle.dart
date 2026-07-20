part of 'messaging_core.dart';

typedef _InboundContentStreamHandler =
    void Function(NodeId peer, ReliableStream stream);

/// One accept loop per transport, independent of a particular
/// [MessagingService] instance.
///
/// Riverpod can replace a messaging service synchronously while its previous
/// async `dispose()` is still unwinding.  When every service owns its own
/// polling `acceptStream`, the old native accept can remain parked for two
/// seconds, race the replacement and consume its first inbound stream.  This
/// broker keeps the polling owner stable and atomically hands accepted streams
/// to the latest lease instead.
class _InboundContentStreamBroker {
  _InboundContentStreamBroker._(this._transport);

  static final Expando<_InboundContentStreamBroker> _byTransport =
      Expando<_InboundContentStreamBroker>('xveil-content-stream-broker');

  static _InboundContentStreamBroker forTransport(StreamTransport transport) =>
      _byTransport[transport] ??= _InboundContentStreamBroker._(transport);

  final StreamTransport _transport;
  _InboundContentStreamLeaseState? _current;
  Future<void>? _loop;

  _InboundContentStreamLease attach({
    required bool acceptP2P,
    required _InboundContentStreamHandler onAnonymous,
    required _InboundContentStreamHandler onP2P,
  }) {
    final token = Object();
    _current = _InboundContentStreamLeaseState(
      token: token,
      acceptP2P: acceptP2P,
      onAnonymous: onAnonymous,
      onP2P: onP2P,
    );
    _ensureLoops();
    return _InboundContentStreamLease(this, token);
  }

  void _detach(Object token) {
    if (identical(_current?.token, token)) _current = null;
  }

  void _ensureLoops() {
    if (_loop != null) return;
    late final Future<void> loop;
    loop = _run().whenComplete(() {
      if (identical(_loop, loop)) _loop = null;
      if (_current != null) _ensureLoops();
    });
    _loop = loop;
    unawaited(loop);
  }

  Future<void> _run() async {
    while (_current != null) {
      final transport = _transport;
      final p2pTransport = transport is P2PStreamTransport
          ? transport as P2PStreamTransport
          : null;
      if ((_current?.acceptP2P ?? false) && p2pTransport != null) {
        try {
          final accepted = await p2pTransport.acceptP2PStream(
            timeout: const Duration(milliseconds: 250),
          );
          if (accepted != null) {
            final lease = _current;
            if (lease == null || !lease.acceptP2P) {
              await _abort(accepted.stream);
            } else {
              try {
                lease.onP2P(accepted.src, accepted.stream);
              } catch (_) {
                await _abort(accepted.stream);
              }
            }
            continue;
          }
        } catch (e) {
          if (_current == null) return;
          devLog(() => 'xVeil[content]: acceptP2PStream error: $e');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      try {
        final accepted = await transport.acceptStream(
          timeout: const Duration(seconds: 2),
        );
        if (accepted == null) continue;
        final lease = _current;
        if (lease == null) {
          await _abort(accepted.stream);
          continue;
        }
        try {
          lease.onAnonymous(accepted.src, accepted.stream);
        } catch (_) {
          await _abort(accepted.stream);
        }
      } catch (e) {
        if (_current == null) return;
        devLog(() => 'xVeil[content]: acceptStream error: $e');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  static Future<void> _abort(ReliableStream stream) async {
    try {
      await stream.abort();
    } catch (_) {}
  }
}

class _InboundContentStreamLeaseState {
  const _InboundContentStreamLeaseState({
    required this.token,
    required this.acceptP2P,
    required this.onAnonymous,
    required this.onP2P,
  });

  final Object token;
  final bool acceptP2P;
  final _InboundContentStreamHandler onAnonymous;
  final _InboundContentStreamHandler onP2P;
}

class _InboundContentStreamLease {
  _InboundContentStreamLease(this._broker, this._token);

  final _InboundContentStreamBroker _broker;
  final Object _token;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _broker._detach(_token);
  }
}

/// Owns every background reliable-stream task started by one messaging service.
/// Detaching the broker lease is synchronous; aborting and joining native
/// streams is asynchronous and completed by [dispose].
class _MessagingContentStreamLifecycle {
  _InboundContentStreamLease? _lease;
  bool _closing = false;
  final Completer<void> _closingSignal = Completer<void>();

  final Set<ReliableStream> _serveStreams = Set<ReliableStream>.identity();
  final Set<Future<void>> _serveJobs = <Future<void>>{};
  final Map<String, Set<_TrackedPullStream>> _pullStreams = {};
  final Set<Future<void>> _pullJobs = <Future<void>>{};

  bool get closing => _closing;

  void attach(
    StreamTransport transport, {
    required bool acceptP2P,
    required _InboundContentStreamHandler onAnonymous,
    required _InboundContentStreamHandler onP2P,
  }) {
    if (_closing || _lease != null) return;
    _lease = _InboundContentStreamBroker.forTransport(
      transport,
    ).attach(acceptP2P: acceptP2P, onAnonymous: onAnonymous, onP2P: onP2P);
  }

  void runServe(ReliableStream stream, Future<void> Function() body) {
    if (_closing) {
      unawaited(_abort(stream));
      return;
    }
    _serveStreams.add(stream);
    late final Future<void> job;
    job = Future<void>.sync(body).whenComplete(() {
      _serveStreams.remove(stream);
      _serveJobs.remove(job);
    });
    _serveJobs.add(job);
    unawaited(job.catchError((_) {}));
  }

  void runPull(Future<void> Function() body) {
    if (_closing) return;
    late final Future<void> job;
    job = Future<void>.sync(body).whenComplete(() => _pullJobs.remove(job));
    _pullJobs.add(job);
    unawaited(job.catchError((_) {}));
  }

  ReliableStream trackPull(String contentId, ReliableStream stream) {
    late final _TrackedPullStream tracked;
    tracked = _TrackedPullStream(stream, () {
      final active = _pullStreams[contentId];
      active?.remove(tracked);
      if (active?.isEmpty ?? false) _pullStreams.remove(contentId);
    });
    if (_closing) {
      unawaited(tracked.abort());
      return tracked;
    }
    _pullStreams.putIfAbsent(contentId, () => {}).add(tracked);
    return tracked;
  }

  Future<void> abortPulls(String contentId) async {
    final streams = _pullStreams[contentId]?.toList(growable: false);
    if (streams == null) return;
    await Future.wait([for (final stream in streams) _abort(stream)]);
  }

  /// Return promptly when this service starts closing even if a native stream
  /// open is still parked. The native future cannot be cancelled, so a stream
  /// that arrives later is asynchronously aborted instead of leaking a handle
  /// or being adopted by the disposed service.
  Future<ReliableStream?> awaitOpen(
    Future<ReliableStream?> pending, {
    Duration? timeout,
  }) async {
    final outcome = pending.then<_StreamOpenOutcome>(
      _StreamOpenOutcome.value,
      onError: (Object error, StackTrace stackTrace) =>
          _StreamOpenOutcome.error(error, stackTrace),
    );
    if (_closing) {
      unawaited(_abortLateOpen(outcome));
      return null;
    }
    Timer? timeoutTimer;
    final timeoutSignal = Completer<_StreamOpenOutcome>();
    if (timeout != null) {
      timeoutTimer = Timer(
        timeout,
        () => timeoutSignal.complete(_StreamOpenOutcome.cancelled()),
      );
    }
    late final _StreamOpenOutcome result;
    try {
      result = await Future.any([
        outcome,
        _closingSignal.future.then((_) => _StreamOpenOutcome.cancelled()),
        if (timeout != null) timeoutSignal.future,
      ]);
    } finally {
      timeoutTimer?.cancel();
    }
    if (result.cancelled) {
      unawaited(_abortLateOpen(outcome));
      return null;
    }
    if (result.error != null) {
      Error.throwWithStackTrace(result.error!, result.stackTrace!);
    }
    final stream = result.stream;
    if (_closing && stream != null) {
      await _abort(stream);
      return null;
    }
    return stream;
  }

  Future<void> dispose() async {
    if (_closing) return;
    _closing = true;
    _closingSignal.complete();
    _lease?.close();
    _lease = null;

    await Future.wait([
      for (final stream in _serveStreams.toList(growable: false))
        _abort(stream),
      for (final streams in _pullStreams.values)
        for (final stream in streams.toList(growable: false)) _abort(stream),
    ]);
    await Future.wait([
      for (final job in _serveJobs.toList(growable: false)) _settle(job),
      for (final job in _pullJobs.toList(growable: false)) _settle(job),
    ]);
    _serveStreams.clear();
    _serveJobs.clear();
    _pullStreams.clear();
    _pullJobs.clear();
  }

  static Future<void> _abort(ReliableStream stream) async {
    try {
      await stream.abort();
    } catch (_) {}
  }

  static Future<void> _settle(Future<void> job) async {
    try {
      await job;
    } catch (_) {}
  }

  static Future<void> _abortLateOpen(Future<_StreamOpenOutcome> outcome) async {
    final result = await outcome;
    if (result.stream != null) await _abort(result.stream!);
  }
}

class _StreamOpenOutcome {
  const _StreamOpenOutcome._({
    this.stream,
    this.error,
    this.stackTrace,
    this.cancelled = false,
  });

  factory _StreamOpenOutcome.value(ReliableStream? stream) =>
      _StreamOpenOutcome._(stream: stream);

  factory _StreamOpenOutcome.error(Object error, StackTrace stackTrace) =>
      _StreamOpenOutcome._(error: error, stackTrace: stackTrace);

  factory _StreamOpenOutcome.cancelled() =>
      const _StreamOpenOutcome._(cancelled: true);

  final ReliableStream? stream;
  final Object? error;
  final StackTrace? stackTrace;
  final bool cancelled;
}

/// Registers a receive-side stream until it closes or aborts. This gives a
/// user cancellation a concrete native handle to interrupt even while Dart is
/// blocked in [ReliableStream.read].
class _TrackedPullStream implements ReliableStream {
  _TrackedPullStream(this._inner, this._onDone);

  final ReliableStream _inner;
  final void Function() _onDone;
  bool _done = false;

  @override
  Future<void> write(Uint8List data) => _inner.write(data);

  @override
  Future<Uint8List> read({int maxBytes = 64 * 1024}) =>
      _inner.read(maxBytes: maxBytes);

  @override
  Future<void> close() => _finish(_inner.close);

  @override
  Future<void> abort() => _finish(_inner.abort);

  Future<void> _finish(Future<void> Function() action) async {
    if (_done) return;
    _done = true;
    try {
      await action();
    } finally {
      _onDone();
    }
  }
}
