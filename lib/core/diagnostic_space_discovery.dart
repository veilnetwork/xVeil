import 'package:veil_flutter/veil_ffi.dart' show VeilException;

import 'diagnostic_journal.dart';

/// Classify without stringifying an exception or retaining native error text.
/// The one exact native label is a fixed SDK result, never a user identifier.
void recordSpaceDiscoveryFailure(
  Object error, {
  required SpaceDiscoveryFailureStage stage,
  DiagnosticJournal? journal,
}) {
  final failure = switch (error) {
    VeilException(message: 'no embedded node running for this identity') =>
      SpaceDiscoveryFailureKind.nodeUnavailable,
    VeilException() => SpaceDiscoveryFailureKind.nativeCall,
    FormatException() => SpaceDiscoveryFailureKind.invalidData,
    StateError() => SpaceDiscoveryFailureKind.localState,
    ArgumentError() => SpaceDiscoveryFailureKind.binding,
    _ => SpaceDiscoveryFailureKind.other,
  };
  (journal ?? diagnosticJournal).recordSpaceDiscoveryFailure(
    stage: stage,
    failure: failure,
  );
}
