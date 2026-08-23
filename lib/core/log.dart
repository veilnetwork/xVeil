import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io' as io;

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

/// Echo [devLog] to stdout as well, for a host with no debugger and no debug
/// hook — the headless daemon.
///
/// Read INSIDE the compile-time gate below, never outside it. In a release
/// build that whole branch is dead-code-eliminated, so this variable is not
/// consulted, the thunk is not called, and no node-id-bearing string is
/// constructed: the anonymity property the gate exists for is unchanged, and
/// this cannot be flipped on in a distribution build.
///
/// It exists because the daemon could see none of its own diagnostics. Its app
/// log went to `developer.log`, which the file's own comment already notes is
/// invisible to a captured stdout; the ring buffer was filled but the daemon
/// exposes no `/dev_log` hook to read it. And the documented escape hatch —
/// "a DIAGNOSTIC release build with `--dart-define=XVEIL_RELEASE_LOG=true`" —
/// cannot be built for this target at all: `dart build cli` is the only command
/// that handles its native build hooks, and it takes no `--define`.
///
/// So a daemon whose whole purpose is unattended bots and server integrations
/// had no way to answer "why did that not send", in any build.
/// Resolved once: an environment lookup per logged line would be a map probe
/// on a path that runs thousands of times a minute on a busy node.
final bool _echoToStdout =
    !_productMode && io.Platform.environment['XVEIL_LOG_STDOUT'] == '1';

void devLog(String Function() message) {
  if (!_productMode || _releaseDiagnosticLog) {
    final line = message();
    developer.log(line, name: 'xVeil');
    if (_echoToStdout) {
      io.stdout.writeln('xVeil: $line');
    }
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
