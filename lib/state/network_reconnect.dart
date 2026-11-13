import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../core/diagnostic_journal.dart';
import '../core/diagnostic_background.dart';
import '../data/transport/veil_transport.dart';
import 'providers.dart';

NetworkAttachment networkAttachmentOf(List<ConnectivityResult> results) {
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
    return NetworkAttachment.offline;
  }
  if (results.contains(ConnectivityResult.wifi)) return NetworkAttachment.wifi;
  if (results.contains(ConnectivityResult.ethernet)) {
    return NetworkAttachment.ethernet;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return NetworkAttachment.cellular;
  }
  return NetworkAttachment.unknown;
}

/// Serialized, bounded handover notifications. Duplicate OS observations do
/// not repeatedly tear down sessions; a new state during an IPC await is kept
/// as the next observation, rather than launching overlapping reconnects.
class NetworkReconnect {
  NetworkReconnect({
    required this.current,
    required this.changes,
    required this.notify,
    this.onAttachmentChanged,
  });

  final Future<List<ConnectivityResult>> Function() current;
  final Stream<List<ConnectivityResult>> changes;
  // Generation distinguishes wifi -> cellular -> wifi from a retry of the
  // same observation. Fanout uses it to retry only failed identity nodes.
  final Future<void> Function(NetworkAttachment, int generation) notify;
  final void Function()? onAttachmentChanged;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  NetworkAttachment? _desired;
  int _desiredGeneration = 0;
  int _appliedGeneration = 0;
  bool _busy = false;
  bool _disposed = false;
  int _observations = 0;
  Timer? _retryTimer;
  int _retrySeconds = 1;

  Future<void> start() async {
    if (_disposed || _subscription != null) return;
    // Listen first: an old checkConnectivity answer must not overwrite a
    // newer handover event delivered while the platform query was pending.
    _subscription = changes.listen(_observe, onError: (Object _) {});
    final before = _observations;
    try {
      final initial = await current();
      if (!_disposed && _observations == before) _observe(initial);
    } catch (_) {
      // A later platform event can still restore the observation.
    }
  }

  void _observe(List<ConnectivityResult> results) {
    if (_disposed) return;
    _observations++;
    final attachment = networkAttachmentOf(results);
    if (attachment != _desired) {
      _desired = attachment;
      _desiredGeneration++;
      _retrySeconds = 1;
      try {
        onAttachmentChanged?.call();
      } catch (_) {
        // Optional evidence must not prevent network repair.
      }
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_busy) unawaited(_drain());
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer != null) return;
    _retryTimer = Timer(Duration(seconds: _retrySeconds), () {
      _retryTimer = null;
      if (!_disposed && !_busy) unawaited(_drain());
    });
    _retrySeconds = (_retrySeconds * 2).clamp(1, 30);
  }

  Future<void> _drain() async {
    _busy = true;
    try {
      while (!_disposed && _desiredGeneration != _appliedGeneration) {
        final next = _desired!;
        final generation = _desiredGeneration;
        final timing = Stopwatch()..start();
        var success = false;
        try {
          await notify(next, generation);
          _appliedGeneration = generation;
          _retrySeconds = 1;
          success = true;
        } catch (_) {
          devLog(() => 'xVeil[net]: handover notification failed');
          // IPC can fail while the node restarts during handover, with no
          // further OS event forthcoming. Retry with one bounded timer and
          // no overlapping notifications; a newer observation runs now.
          if (_desiredGeneration == generation) {
            _scheduleRetry();
            break;
          }
        } finally {
          diagnosticJournal.record(
            DiagnosticEvent.networkChange,
            values: {
              DiagnosticMetric.state: next.index,
              DiagnosticMetric.success: success ? 1 : 0,
              DiagnosticMetric.durationMs: timing.elapsedMilliseconds,
            },
          );
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _subscription?.cancel();
  }
}

final networkConnectivityProvider = Provider<Connectivity>(
  (_) => Connectivity(),
);

final networkReconnectProvider = Provider<void>((ref) {
  final connectivity = ref.watch(networkConnectivityProvider);
  final diagnostics = DiagnosticBackgroundSampler();
  final observations = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );
  final observers = Map<NetworkChangeTransport, NetworkReconnect>.identity();
  final notifying = Set<NetworkChangeTransport>.identity();
  List<ConnectivityResult>? latest;
  Future<List<ConnectivityResult>>? initialQuery;
  NetworkAttachment? diagnosticAttachment;
  var disposed = false;

  void remember(List<ConnectivityResult> results) {
    latest = List<ConnectivityResult>.unmodifiable(results);
    final attachment = networkAttachmentOf(results);
    if (attachment != diagnosticAttachment) {
      diagnosticAttachment = attachment;
      diagnostics.request();
    }
  }

  Future<List<ConnectivityResult>> current() async {
    final observed = latest;
    if (observed != null) return observed;
    final pending = initialQuery ??= connectivity.checkConnectivity();
    try {
      final results = await pending;
      // An event received during the platform query is newer. New identity
      // nodes also start from that latest observation, not the old query.
      if (!disposed && latest == null) remember(results);
      return latest ?? results;
    } finally {
      if (identical(initialQuery, pending)) initialQuery = null;
    }
  }

  void synchronize() {
    if (disposed) return;
    final active = ref.read(realStackProvider);
    final session = ref.read(sessionProvider);
    final transports = Set<NetworkChangeTransport>.identity()
      ..addAll([
        if (active?.transport case final NetworkChangeTransport transport)
          transport,
        if (session != null)
          for (final label in session.labels)
            if (session.stackFor(label)?.transport
                case final NetworkChangeTransport transport)
              transport,
      ]);
    for (final transport in observers.keys.toList()) {
      if (!transports.contains(transport)) {
        unawaited(observers.remove(transport)!.dispose());
      }
    }
    for (final transport in transports) {
      if (observers.containsKey(transport) || notifying.contains(transport)) {
        continue;
      }
      // Separate identity nodes need independent receipt/retry queues. A slow
      // node must not hold the next handover of an otherwise healthy node.
      // Reuse the same OS subscription/snapshot and deduplicate an active node
      // that also appears in the all-online session by object identity.
      late final NetworkReconnect observer;
      observer = NetworkReconnect(
        current: current,
        changes: observations.stream,
        notify: (attachment, _) async {
          if (disposed || !identical(observers[transport], observer)) return;
          notifying.add(transport);
          try {
            await transport.networkChanged(attachment);
          } finally {
            notifying.remove(transport);
            // Removal retires its observer, not the already admitted native
            // operation. If that same node returns before completion, start
            // its fresh observer only once this operation has settled.
            if (!disposed && !observers.containsKey(transport)) synchronize();
          }
        },
      );
      observers[transport] = observer;
      unawaited(observer.start());
    }
  }

  final subscription = connectivity.onConnectivityChanged.listen((results) {
    if (disposed) return;
    remember(results);
    // Keep the original fresh target lookup even if a session updated its
    // node set without replacing the provider's session object.
    synchronize();
    observations.add(latest!);
  }, onError: (Object _) {});

  ref.listen(realStackProvider, (_, _) => synchronize());
  ref.listen(sessionProvider, (_, _) => synchronize());
  ref.onDispose(() {
    disposed = true;
    diagnostics.dispose();
    unawaited(subscription.cancel());
    unawaited(
      Future.wait([
        for (final observer in observers.values) observer.dispose(),
      ]).whenComplete(observations.close),
    );
    observers.clear();
  });
  synchronize();
});
