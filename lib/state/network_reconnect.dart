import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../core/diagnostic_journal.dart';
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
  });

  final Future<List<ConnectivityResult>> Function() current;
  final Stream<List<ConnectivityResult>> changes;
  final Future<void> Function(NetworkAttachment) notify;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  NetworkAttachment? _desired;
  int _desiredGeneration = 0;
  int _appliedGeneration = 0;
  bool _busy = false;
  bool _disposed = false;
  int _observations = 0;

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
    }
    if (!_busy) unawaited(_drain());
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
          await notify(next);
          _appliedGeneration = generation;
          success = true;
        } catch (_) {
          devLog(() => 'xVeil[net]: handover notification failed');
          // Retain an unapplied state for the next OS observation. A newer
          // state already waiting must still be attempted now.
          if (_desiredGeneration == generation) break;
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
    await _subscription?.cancel();
  }
}

final networkConnectivityProvider = Provider<Connectivity>(
  (_) => Connectivity(),
);

final networkReconnectProvider = Provider<void>((ref) {
  final connectivity = ref.watch(networkConnectivityProvider);
  final observer = NetworkReconnect(
    current: connectivity.checkConnectivity,
    changes: connectivity.onConnectivityChanged,
    notify: (attachment) async {
      final active = ref.read(realStackProvider);
      final session = ref.read(sessionProvider);
      final transports = <NetworkChangeTransport>{
        if (active?.transport case final NetworkChangeTransport transport)
          transport,
        if (session != null)
          for (final label in session.labels)
            if (session.stackFor(label)?.transport
                case final NetworkChangeTransport transport)
              transport,
      };
      // All online identities are separate nodes. Notify each once, including
      // the active identity that is also present in an all-online session.
      await Future.wait([
        for (final transport in transports)
          transport.networkChanged(attachment),
      ]);
    },
  );
  ref.onDispose(() => unawaited(observer.dispose()));
  unawaited(observer.start());
});
