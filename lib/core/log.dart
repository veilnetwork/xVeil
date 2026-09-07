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

/// The file a debug build writes its log to, opened once and appended to.
///
/// A person hitting a crash cannot send a log that was never written down.
/// `developer.log` needs a debugger attached, the stdout echo needs a console —
/// which a GUI process on Windows does not have — and the ring buffer dies with
/// the process, which is precisely the moment its contents were wanted. So a
/// build that logs at all also writes the log where the person can find it
/// without being told anything but "the folder you started it from".
///
/// INSIDE the same compile-time gate as [devLog] itself: a distribution build
/// evaluates none of this, opens no file, and pays nothing. The anonymity
/// argument is unchanged — these lines carry node ids, and the build that
/// emits them is the one somebody asked for.
///
/// Appended and FLUSHED per line, deliberately. A buffered sink loses its tail
/// exactly when the process dies, and the tail is the part a crash report is
/// about.
io.RandomAccessFile? _logFileHandle;
bool _logFileTried = false;

/// Bytes above which the file is started over on the next launch.
///
/// Rotation rather than a cap: the newest run is the one being asked about,
/// and an old log that stops the new one from being written would be the worst
/// of both.
const int _logFileRotateAbove = 16 * 1024 * 1024;

/// Where the log went, for the line the app prints at startup so nobody has to
/// guess. Null until [_openLogFile] has run.
String? devLogFilePath;

/// Where the logs go, in preference order.
///
/// Beside the binary that is running, which is the one place a person can
/// describe over a chat window. `resolvedExecutable` and not the working
/// directory: a shortcut, a file manager and a terminal all disagree about the
/// latter. The temp directory is the fallback for an install under Program
/// Files or on a read-only mount — a log somewhere is worth more than a
/// permission error.
List<String> _logDirCandidates() {
  final override = devLogDirectoryOverride;
  if (override != null) return <String>[override];
  return <String>[
    io.File(io.Platform.resolvedExecutable).parent.path,
    io.Directory.systemTemp.path,
  ];
}

/// Where the log goes instead, for tests and stands.
///
/// The default answer is "beside the running binary", which is right for the
/// app and wrong for a test suite: under `flutter test` the running binary is
/// `flutter_tester`, so the suite wrote its log INTO the Flutter SDK's cache
/// directory — and dozens of parallel test processes appended to one file
/// there, which then failed to decode as UTF-8. A shared folder nobody chose
/// is a bad place for a log even when it does decode.
///
/// Setting this reopens the file on the next line written.
String? _logDirectoryOverride;
String? get devLogDirectoryOverride => _logDirectoryOverride;
set devLogDirectoryOverride(String? dir) {
  _logDirectoryOverride = dir;
  try {
    _logFileHandle?.closeSync();
  } catch (_) {
    // Already gone; nothing to do but forget it.
  }
  _logFileHandle = null;
  _logFileTried = false;
  devLogFilePath = null;
}

/// The file the NODE writes its own log to, beside the app's.
///
/// Half of a crash report lives there: the node is a separate runtime with its
/// own view of transports and peers, and on a GUI process its stderr goes
/// nowhere a person can reach. Both files in one folder makes "send me what is
/// next to the exe" the whole instruction.
///
/// Null in a distribution build, which writes neither. Returns a PATH without
/// creating anything: the node opens it.
String? debugNodeLogPath() {
  if (_productMode && !_releaseDiagnosticLog) return null;
  for (final dir in _logDirCandidates()) {
    final probe = io.File('$dir${io.Platform.pathSeparator}.xveil-write-probe');
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return '$dir${io.Platform.pathSeparator}xveil-node-debug.log';
    } catch (_) {
      // Not writable — try the next.
    }
  }
  return null;
}

io.RandomAccessFile? _openLogFile() {
  if (_logFileTried) return _logFileHandle;
  _logFileTried = true;
  // A test process writes nothing unless it asked to. `flutter test` runs
  // `flutter_tester` out of the SDK's cache, so "beside the running binary"
  // means inside somebody else's installation — shared with every other test
  // process on the machine, which is how a suite of four thousand tests
  // produced one file that no longer decoded as UTF-8.
  if (_logDirectoryOverride == null &&
      io.Platform.environment['FLUTTER_TEST'] == 'true') {
    return null;
  }
  for (final dir in _logDirCandidates()) {
    try {
      final file = io.File('$dir${io.Platform.pathSeparator}xveil-debug.log');
      if (file.existsSync() && file.lengthSync() > _logFileRotateAbove) {
        file.deleteSync();
      }
      final handle = file.openSync(mode: io.FileMode.append);
      devLogFilePath = file.path;
      _logFileHandle = handle;
      return handle;
    } catch (_) {
      // Program Files is not writable, a read-only mount, a sandbox: try the
      // next place rather than losing the log to a permission error.
    }
  }
  return null;
}

/// Consecutive write failures, and the point at which the sink gives up.
///
/// Reopening rather than giving up on the first one, because the first one is
/// LIKELY and temporary: on Windows a reader that opens the file without
/// sharing writes — which is what copying it with an ordinary tool does —
/// makes the next write throw. That is precisely the moment a person is
/// collecting the log to send it, and the old behaviour was to stop writing
/// for the rest of the session. Measured on the stand: eleven lines, then
/// silence through an unlock, a node start and everything after.
///
/// Bounded so a disk that is genuinely full does not turn every logged line
/// into an open/write/close storm.
int _logFileFailures = 0;
const int _logFileGiveUpAfter = 5;

void _writeLogFile(String line) {
  if (_logFileFailures >= _logFileGiveUpAfter) return;
  final handle = _openLogFile();
  if (handle == null) return;
  try {
    handle.writeStringSync('$line\n');
    handle.flushSync();
    _logFileFailures = 0;
  } catch (_) {
    // A disk that filled up or a handle that went away must not take the app
    // with it, and must not silence it either: drop the handle and let the
    // next line open a fresh one.
    _logFileFailures++;
    try {
      _logFileHandle?.closeSync();
    } catch (_) {
      // Already unusable; there is nothing to salvage.
    }
    _logFileHandle = null;
    _logFileTried = false;
  }
}

void devLog(String Function() message) {
  if (!_productMode || _releaseDiagnosticLog) {
    final line = message();
    developer.log(line, name: 'xVeil');
    _devLogSeq++;
    // One stamp for both sinks. The echo carried no time at first, which made
    // it useless for the first question anyone asks a diagnostic log — how
    // OFTEN — while the ring right beside it had the answer.
    final stamped = '${DateTime.now().toIso8601String()} #$_devLogSeq $line';
    if (_echoToStdout) {
      io.stdout.writeln('xVeil: $stamped');
    }
    _writeLogFile(stamped);
    _devLogRing.addLast(stamped);
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
