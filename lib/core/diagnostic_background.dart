import 'dart:async';

import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import 'diagnostic_journal.dart';

/// Bounded, read-only probe. Ordinary builds never call the platform channel.
Future<void> sampleDiagnosticBackgroundState({
  DiagnosticJournal? journal,
  Future<Map<Object?, Object?>?> Function()? readState,
}) async {
  final target = journal ?? diagnosticJournal;
  if (!target.enabled) return;
  try {
    final state = await (readState ?? VeilBackground.diagnosticState)().timeout(
      const Duration(seconds: 1),
    );
    target.recordBackgroundState(state);
  } catch (_) {
    // Neither plugin exception text nor method arguments leave the process.
    target.record(
      DiagnosticEvent.backgroundSnapshot,
      values: {DiagnosticMetric.success: 0},
    );
  }
}

/// Handover must never wait for diagnostics. Keep at most one native read and
/// one coalesced follow-up, even if the platform read outlives our timeout.
class DiagnosticBackgroundSampler {
  DiagnosticBackgroundSampler({DiagnosticJournal? journal, this.readState})
    : journal = journal ?? diagnosticJournal;

  final DiagnosticJournal journal;
  final Future<Map<Object?, Object?>?> Function()? readState;
  bool _busy = false;
  bool _pending = false;
  bool _disposed = false;

  void request() {
    if (_disposed || !journal.enabled) return;
    _pending = true;
    if (!_busy) unawaited(_drain());
  }

  Future<void> _drain() async {
    _busy = true;
    try {
      while (_pending && !_disposed) {
        _pending = false;
        final read = Future<Map<Object?, Object?>?>.sync(
          readState ?? VeilBackground.diagnosticState,
        );
        // Attach the error handler before a synchronous plugin failure can
        // reach the event loop. Do not release the slot on timeout alone.
        final settled = read.then<void>((_) {}, onError: (Object _) {});
        await sampleDiagnosticBackgroundState(
          journal: journal,
          readState: () => read,
        );
        await settled;
      }
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    _pending = false;
  }
}
