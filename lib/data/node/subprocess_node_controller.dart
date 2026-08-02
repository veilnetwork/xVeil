import 'dart:async';

import 'node_controller.dart';
import 'process_launcher.dart';

/// Resolves true once the node's IPC socket is reachable. Injected so the
/// production probe (socket connect) and a test probe share one seam.
typedef ReadinessProbe = Future<bool> Function();

/// [NodeController] that runs the node as a child process — `veil-cli node run`
/// — and reports it connected once its IPC socket answers. This is the
/// "hybrid: subprocess now" strategy; an embedded-FFI controller can replace it
/// later behind the same port.
///
/// The exact executable/args and the readiness probe are injected rather than
/// hard-coded, so the lifecycle (start → starting → connected, crash → error,
/// stop → stopped) is verified without a real binary.
class SubprocessNodeController implements NodeController {
  SubprocessNodeController({
    required this.executable,
    required this.args,
    required this.readinessProbe,
    this.launcher = const IoProcessLauncher(),
    this.workingDirectory,
    this.environment,
    this.readinessTimeout = const Duration(seconds: 25),
    this.pollInterval = const Duration(milliseconds: 300),
  });

  final String executable;
  final List<String> args;
  final ReadinessProbe readinessProbe;
  final ProcessLauncher launcher;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final Duration readinessTimeout;
  final Duration pollInterval;

  final _status = StreamController<NodeStatus>.broadcast();
  NodeStatus _current = NodeStatus.stopped;
  NodeProcess? _process;
  StreamSubscription<int>? _exitWatch;
  bool _economy = false;

  @override
  NodeStatus get current => _current;

  @override
  Stream<NodeStatus> status() => _status.stream;

  void _emit(NodeStatus s) {
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  Future<void> start() async {
    if (_current.phase == NodePhase.starting ||
        _current.phase == NodePhase.connected) {
      return;
    }
    _emit(const NodeStatus(phase: NodePhase.starting));

    // If a node is already running (e.g. left over from a previous session),
    // adopt it instead of spawning a duplicate.
    if (await readinessProbe()) {
      _emit(const NodeStatus(phase: NodePhase.connected));
      return;
    }

    final NodeProcess process;
    try {
      process = await launcher.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } catch (e) {
      _emit(NodeStatus(phase: NodePhase.error, message: 'spawn failed: $e'));
      return;
    }
    _process = process;

    // DRAIN BOTH PIPES (audit XV-20). Nothing read them, so once the OS pipe
    // buffer filled — 64 KiB on Linux, less elsewhere — the node BLOCKED on its
    // next write and stopped doing anything, with no error anywhere: a node
    // that talks too much wedged itself, and the amount it talks depends on log
    // level and traffic. A bounded tail is kept so the reason a node died is
    // still visible; the rest is discarded rather than accumulated.
    _tail.clear();
    _drains = [
      process.stdoutLines.listen(_recordLine, onError: (_) {}),
      process.stderrLines.listen(_recordLine, onError: (_) {}),
    ];

    var exited = false;
    _exitWatch = process.exitCode.asStream().listen((code) {
      exited = true;
      if (_current.phase != NodePhase.stopped) {
        _emit(NodeStatus(
          phase: NodePhase.error,
          message: 'node exited with code $code',
        ));
      }
    });

    final deadline = DateTime.now().add(readinessTimeout);
    while (!exited && DateTime.now().isBefore(deadline)) {
      if (await readinessProbe()) {
        _emit(const NodeStatus(phase: NodePhase.connected));
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
    if (!exited && _current.phase != NodePhase.connected) {
      // KILL IT (audit XV-20). Giving up on the WAIT used to leave the child
      // RUNNING and unowned: it kept the admin socket and the listen port, and
      // the next `start()` — seeing no readiness — spawned a second one beside
      // it. Same shape as the stranded all-online node in XV-05: we stopped
      // watching and called that stopping.
      await _terminate();
      _emit(const NodeStatus(
        phase: NodePhase.error,
        message: 'node did not become ready before timeout',
      ));
    }
  }

  /// Longest we wait for a killed child to actually go away before giving up on
  /// a clean reap. Short: the process was already told to die, and a caller
  /// blocked here is a UI that appears frozen.
  static const _exitGrace = Duration(seconds: 5);

  /// Stop the child and WAIT for it, so the caller's next `start()` cannot race
  /// a process that still holds the port.
  Future<void> _terminate() async {
    final process = _process;
    _process = null;
    for (final d in _drains) {
      unawaited(d.cancel());
    }
    _drains = const [];
    await _exitWatch?.cancel();
    _exitWatch = null;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(_exitGrace);
    } catch (_) {
      // Did not die in time (or already reaped). Nothing further to do from
      // here — the handle is released either way, and holding the caller
      // longer would not change the outcome.
    }
  }

  /// Bounded tail of the child's output, newest last.
  final List<String> _tail = <String>[];
  static const _tailLines = 200;
  List<StreamSubscription<String>> _drains = const [];

  void _recordLine(String line) {
    _tail.add(line);
    if (_tail.length > _tailLines) _tail.removeAt(0);
  }

  /// What the node last said before it stopped — for diagnostics.
  List<String> get outputTail => List.unmodifiable(_tail);

  @override
  Future<void> setEconomyMode(bool economy) async {
    // The keepalive/battery scaling is driven through the transport
    // (VeilClient.setBackgroundMode); here we only record intent so a future
    // admin-socket command can act on it.
    _economy = economy;
  }

  bool get economyMode => _economy;

  @override
  Future<void> stop() async {
    // Awaits the exit (audit XV-20): this used to `kill()` and return
    // immediately, so a `start()` right after could spawn while the old process
    // still held the admin socket and the listen port — and the old handle was
    // already dropped, so nobody could stop it either.
    await _terminate();
    _emit(NodeStatus.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }
}
