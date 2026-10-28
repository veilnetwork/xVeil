// Run with dart compile exe -DXVEIL_DIAGNOSTICS=true and the app's package
// config. Explicit checks stay active in product AOT, where asserts do not.
import 'dart:convert';
import 'dart:io';

import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

void main() {
  if (!const bool.fromEnvironment('dart.vm.product') ||
      !kDiagnosticReportEnabled) {
    throw StateError('Not a diagnostic product AOT build');
  }
  final adapter = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
  if (adapter.bufferDiagnostics.isNotEmpty) {
    throw StateError('Stand history enabled');
  }
  final journal = DiagnosticJournal();
  journal.recordVideoDelivery({
    ...adapter.videoDeliveryDiagnostics,
    'peer': 'private-peer-canary',
    'source_epoch': 1793000000000,
  });
  final report = journal.toJson();
  final values = ((report['events'] as List).single as Map)['values'] as Map;
  if (values['videoProbeIntervalMs'] != 3000 ||
      values['videoDeliveryPhase'] != 0) {
    throw StateError('Missing product controller metrics');
  }
  journal.record(
    DiagnosticEvent.callEnded,
    values: {DiagnosticMetric.endReason: 7, DiagnosticMetric.origin: 9},
  );
  for (var i = 0; i < 400; i++) {
    journal.record(DiagnosticEvent.transportReceived);
  }
  final terminal = journal.toJson()['last_call_end'] as Map?;
  if (terminal == null ||
      (terminal['values'] as Map)['endReason'] != 7 ||
      (terminal['values'] as Map)['origin'] != 9) {
    throw StateError('Product terminal cause lost after traffic-ring eviction');
  }
  final terminalText = jsonEncode(journal.toJson());
  if (terminalText.contains('private-peer-canary') ||
      terminalText.contains('source_epoch')) {
    throw StateError('Private data exported with terminal cause');
  }
  final text = jsonEncode(report);
  if (text.contains('private-peer-canary') ||
      text.contains('source_epoch') ||
      text.contains('1793000000000')) {
    throw StateError('Private data exported');
  }
  stdout.writeln(
    'Product AOT controller and terminal reports passed; stand history disabled',
  );
}
