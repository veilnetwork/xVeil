/// Shared plumbing for the end-to-end multi-device harness: the env gate, a
/// wait that always has a deadline AND a diagnostic, port allocation and
/// teardown bookkeeping.
///
/// Two rules this file exists to enforce, both learned the expensive way in
/// this project:
///
///   * A HANG MUST EXPLAIN ITSELF. `Future.timeout` produces "TimeoutException
///     after 0:02:00" and nothing else, and a live multi-device run costs
///     minutes per attempt, so a bare timeout is a re-run with a print
///     statement added. [waitUntil] takes what it is waiting FOR and a probe
///     for what it last SAW, and puts both into the failure.
///   * NOTHING IS SYNCHRONISED BY SLEEPING. A `sleep` either makes the suite
///     slow or makes it flaky, usually both, and it hides the very latency the
///     campaign is measuring. Everything here polls a condition.
library;

import 'dart:async';
import 'dart:io';

/// Every environment variable this suite reads, in one place so the README and
/// the skip message cannot drift from the code.
class E2eGate {
  const E2eGate._({
    required this.veilCli,
    required this.veilDylib,
    required this.hiddenVolumeDylib,
    required this.missing,
  });

  /// A prebuilt `veil-cli`. The suite NEVER builds it: a cargo build inside a
  /// test would put a twenty-minute compile inside a per-test timeout and
  /// report a compiler error as a convergence failure.
  ///
  /// It must be a build with `--features allow-empty-seeds`, because a local
  /// island has no seed list and a binary compiled with the production one
  /// would dial real seed nodes from a test. See the README.
  final String? veilCli;
  final String? veilDylib;
  final String? hiddenVolumeDylib;

  /// The variables that are unset — empty when the suite may run.
  final List<String> missing;

  bool get enabled => missing.isEmpty;

  /// The `skip:` value: `false` when the gate is open, otherwise a sentence
  /// naming exactly what to set. Passed straight to `test(..., skip: …)` so an
  /// ungated `flutter test` reports SKIPPED with instructions rather than a
  /// red failure.
  Object get skip => enabled
      ? false
      : 'multi-device e2e is gated: set ${missing.join(' + ')} '
            '(see test/e2e/README.md)';

  static E2eGate read([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    String? present(String key) {
      final value = env[key];
      if (value == null || value.trim().isEmpty) return null;
      // Absolute + existing, checked HERE: an env override that turns out to
      // be a stale path fails later as "the node never came up", which is the
      // one thing it does not mean.
      final path = value.trim();
      if (!path.startsWith('/')) return null;
      if (!File(path).existsSync()) return null;
      return path;
    }

    final cli = present('XVEIL_E2E_VEIL_CLI');
    final dylib = present('VEIL_FFI_DYLIB');
    final hv = present('HIDDEN_VOLUME_FFI_DYLIB');
    return E2eGate._(
      veilCli: cli,
      veilDylib: dylib,
      hiddenVolumeDylib: hv,
      missing: [
        if (cli == null) 'XVEIL_E2E_VEIL_CLI (absolute path to a veil-cli '
            'built with --features allow-empty-seeds)',
        if (dylib == null) 'VEIL_FFI_DYLIB (absolute path to '
            'libveilclient_ffi)',
        if (hv == null) 'HIDDEN_VOLUME_FFI_DYLIB (absolute path to '
            'libhidden_volume_ffi)',
      ],
    );
  }
}

/// Thrown when a [waitUntil] runs out of time. Carries the description and the
/// last observation so the message is actionable on its own.
class E2eTimeout implements Exception {
  E2eTimeout(this.what, this.elapsed, this.lastSeen, this.lastError);

  final String what;
  final Duration elapsed;
  final String? lastSeen;
  final Object? lastError;

  @override
  String toString() {
    final buffer = StringBuffer('timed out after ${elapsed.inSeconds}s '
        'waiting for: $what');
    buffer.write('\n  last seen: ${lastSeen ?? "(no observation recorded)"}');
    if (lastError != null) buffer.write('\n  last error: $lastError');
    return buffer.toString();
  }
}

/// Poll [condition] until it is true or [timeout] elapses.
///
/// [what] is the sentence that goes into the failure ("B holds A's message").
/// [describe] is called on failure — and periodically while waiting when
/// [E2eLog.verbose] — to say what the current state actually is. It is a
/// callback, not a value, so building the diagnostic costs nothing while the
/// condition is being met on the first poll.
Future<void> waitUntil(
  FutureOr<bool> Function() condition, {
  required String what,
  FutureOr<String> Function()? describe,
  Duration timeout = const Duration(seconds: 120),
  Duration interval = const Duration(milliseconds: 400),
  Duration progressEvery = const Duration(seconds: 15),
}) async {
  final started = DateTime.now();
  final deadline = started.add(timeout);
  String? lastSeen;
  Object? lastError;
  var nextProgress = started.add(progressEvery);

  Future<void> observe() async {
    if (describe == null) return;
    try {
      lastSeen = await describe();
    } catch (error) {
      lastSeen = 'could not describe state: $error';
    }
  }

  while (true) {
    try {
      if (await condition()) return;
      lastError = null;
    } catch (error) {
      // A condition that throws is not a pass and not a failure: a container
      // mid-write, a node that has not opened its socket. Keep the error for
      // the message and keep polling — but never let it masquerade as "not
      // yet true" if it is the only thing that ever happens.
      lastError = error;
    }
    final now = DateTime.now();
    if (!now.isBefore(deadline)) {
      await observe();
      throw E2eTimeout(what, now.difference(started), lastSeen, lastError);
    }
    if (!now.isBefore(nextProgress)) {
      nextProgress = now.add(progressEvery);
      await observe();
      E2eLog.line(
        '… still waiting (${now.difference(started).inSeconds}s) for $what '
        '— last seen: ${lastSeen ?? "?"}'
        '${lastError == null ? "" : " — last error: $lastError"}',
      );
    }
    await Future<void>.delayed(interval);
  }
}

/// The same wait, but the condition RETURNS the thing being waited for. Saves
/// the "poll, then read again" double-read that races on a live device.
Future<T> waitFor<T extends Object>(
  FutureOr<T?> Function() probe, {
  required String what,
  FutureOr<String> Function()? describe,
  Duration timeout = const Duration(seconds: 120),
  Duration interval = const Duration(milliseconds: 400),
}) async {
  T? found;
  await waitUntil(
    () async => (found = await probe()) != null,
    what: what,
    describe: describe,
    timeout: timeout,
    interval: interval,
  );
  return found!;
}

/// Progress reporting for a suite whose individual steps take minutes. Goes to
/// stderr so it interleaves correctly with the test runner's own output.
class E2eLog {
  static final _started = DateTime.now();
  static bool verbose = Platform.environment['XVEIL_E2E_QUIET'] != '1';

  static void line(String message) {
    if (!verbose) return;
    final ms = DateTime.now().difference(_started).inMilliseconds;
    stderr.writeln('[e2e ${(ms / 1000).toStringAsFixed(1)}s] $message');
  }

  static Future<T> step<T>(String what, Future<T> Function() body) async {
    line('▶ $what');
    final at = DateTime.now();
    try {
      final out = await body();
      line('✓ $what (${DateTime.now().difference(at).inMilliseconds}ms)');
      return out;
    } catch (error) {
      line('✗ $what (${DateTime.now().difference(at).inMilliseconds}ms): '
          '$error');
      rethrow;
    }
  }
}

/// A free loopback TCP port.
///
/// Inherently racy — the port is free when asked and could be taken before it
/// is bound — but the alternative (a fixed port) is worse and has already cost
/// this project a day: a second instance silently refused to start because the
/// first still held the metrics port. Every caller that gets one of these also
/// gets a readiness wait, so a lost race fails as "did not come up" with the
/// port in the message rather than as a hang.
Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Whether something is listening on a loopback port.
Future<bool> portAnswers(int port, {Duration timeout = const Duration(milliseconds: 500)}) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Run every leg, then rethrow the FIRST failure.
///
/// Teardown in this suite kills processes, closes containers and removes
/// directories. A throw halfway through a naive `finally` leaves a veil-cli
/// running and a container lock held, and the NEXT run then fails for a reason
/// that has nothing to do with its own code. Every leg runs; the first error
/// is what the caller sees.
Future<void> teardownLegs(String label, List<(String, Future<void> Function())> legs) async {
  Object? first;
  StackTrace? firstTrace;
  for (final (name, leg) in legs) {
    try {
      await leg();
    } catch (error, trace) {
      E2eLog.line('teardown[$label] leg "$name" failed: $error');
      first ??= error;
      firstTrace ??= trace;
    }
  }
  if (first != null) Error.throwWithStackTrace(first, firstTrace!);
}

/// A temp root under `/tmp` rather than under the system temp dir.
///
/// Unix-domain socket paths have a ~104-byte cap on macOS, and the runtime
/// sockets of an embedded node live under this root. The system temp dir on
/// macOS (`/var/folders/xx/yyyy…/T/`) is long enough on its own to blow that
/// cap once a node appends its own directory, and the node then fails to bind
/// with an error that reads like a permissions problem. `public_space_
/// discovery_live_test.dart` already learned this; the comment is here so the
/// next person does not learn it again.
Future<Directory> e2eTempRoot(String prefix) async {
  final root = await Directory('/tmp').createTemp(prefix);
  // A distro shipping umask 002 leaves these group-writable, and the node then
  // refuses to bind its admin socket (a group-writable parent lets someone
  // else pre-create the socket path). The refusal surfaces as "did not
  // converge", which is the one thing it does not mean.
  if (!Platform.isWindows) {
    await Process.run('chmod', ['700', root.path]);
  }
  return root;
}
