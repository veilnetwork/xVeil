import 'package:flutter/foundation.dart';

/// Diagnostic logging that is COMPILED OUT of release builds.
///
/// xVeil's diagnostics embed node-id prefixes, message ids, byte counts and
/// timestamps — precisely the metadata an anonymity / deniability tool must
/// never emit somewhere an adversary can read it (Android `logcat`, a captured
/// stdout, a crash-report pipe). [kDebugMode] is a compile-time `false` in
/// release and profile, so the branch below is dead-code-eliminated by the AOT
/// compiler: nothing prints. The message is a thunk, so the (often
/// node-id-bearing) string is not even constructed in a release build.
///
/// Works uniformly across isolates: each isolate evaluates the same const
/// [kDebugMode], so a worker isolate's diagnostics are silenced in release too —
/// unlike the `debugPrint = noop` trick, which is isolate-local and would miss
/// the storage worker.
/// Compile-time opt-in for a DIAGNOSTIC release build
/// (`--dart-define=XVEIL_RELEASE_LOG=true`): keeps the release AOT/sandbox
/// properties while restoring the trace. Distribution builds never set it, so
/// their logging stays dead-code-eliminated exactly as before.
const _releaseDiagnosticLog = bool.fromEnvironment('XVEIL_RELEASE_LOG');

void devLog(String Function() message) {
  if (kDebugMode || _releaseDiagnosticLog) debugPrint(message());
}
