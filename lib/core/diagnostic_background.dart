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
