import 'dart:collection';
import 'dart:developer' as developer;

/// Diagnostic logging that is COMPILED OUT of release builds.
///
/// xVeil's diagnostics embed node-id prefixes, message ids, byte counts and
/// timestamps — precisely the metadata an anonymity / deniability tool must
/// never emit somewhere an adversary can read it (Android `logcat`, a captured
/// stdout, a crash-report pipe). `dart.vm.product` is a compile-time `true` in
/// release, so the branch below is dead-code-eliminated by the AOT
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
const _productMode = bool.fromEnvironment('dart.vm.product');

/// True in a debug build — the same value as Flutter's `kDebugMode`, computed
/// from the same two compile-time constants, WITHOUT importing Flutter.
///
/// It exists because the headless daemon is a Flutter-free AOT binary: one
/// `package:flutter/foundation.dart` import anywhere it reaches stops it
/// building at all, and `kDebugMode` is a tempting thing to reach for in code
/// the daemon shares with the app. Reach for this instead.
const kXVeilDebugBuild =
    !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile');

/// Bounded in-RAM tail of recent [devLog] lines, readable through the debug
/// hook (`/dev_log`) so a stand driver can see the diagnostic trace without a
/// VM-service attach (developer.log is invisible to nohup/logcat capture).
/// Isolate-local (the hook reads the MAIN isolate's buffer); same compile-time
/// gate as the log itself, so release builds keep emitting nothing and the
/// buffer stays empty. RAM-only by design — never persisted.
const int _devLogRingCapacity = 4000;
final ListQueue<String> _devLogRing = ListQueue<String>();
int _devLogDropped = 0;
int _devLogSeq = 0;

void devLog(String Function() message) {
  if (!_productMode || _releaseDiagnosticLog) {
    final line = message();
    developer.log(line, name: 'xVeil');
    _devLogSeq++;
    _devLogRing.addLast(
      '${DateTime.now().toIso8601String()} #$_devLogSeq $line',
    );
    if (_devLogRing.length > _devLogRingCapacity) {
      _devLogRing.removeFirst();
      _devLogDropped++;
    }
  }
}

/// Snapshot of the newest [limit] buffered lines (oldest first), plus how many
/// older lines were dropped by the ring. Debug-hook consumer only.
({List<String> lines, int dropped, int total}) devLogSnapshot({
  int limit = 500,
}) {
  final all = _devLogRing.toList(growable: false);
  final start = all.length > limit ? all.length - limit : 0;
  return (
    lines: all.sublist(start),
    dropped: _devLogDropped + start,
    total: _devLogSeq,
  );
}
