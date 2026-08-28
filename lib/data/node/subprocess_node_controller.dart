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

  /// Which lifecycle command is the current one.
  ///
  /// A start is a sequence of awaits — the spawn, then a readiness poll that
  /// can run for the whole timeout — and a `stop` arriving in the middle of it
  /// used to find `_process` still null, report `stopped`, and leave the start
  /// to finish: it then spawned or adopted a node and published `connected`
  /// for something the person had just stopped. A stop supersedes a start that
  /// has not finished (report17 XV17-M9).
  int _generation = 0;

  /// True when this controller is watching a node it did NOT spawn.
  ///
  /// Adoption has no handle, so `_terminate` has nothing to kill and used to
  /// report a clean `stopped` for a node that goes on running, holding the
  /// admin socket and the listen port.
  bool _adopted = false;

  @override
  Future<void> start() async {
    if (_current.phase == NodePhase.starting ||
        _current.phase == NodePhase.connected) {
      return;
    }
    final mine = ++_generation;
    _emit(const NodeStatus(phase: NodePhase.starting));

    // If a node is already running (e.g. left over from a previous session),
    // adopt it instead of spawning a duplicate.
    if (await readinessProbe()) {
      if (mine != _generation) return;
      _adopted = true;
      _emit(const NodeStatus(phase: NodePhase.connected));
      return;
    }
    if (mine != _generation) return;

    final NodeProcess process;
    try {
      process = await launcher.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } catch (e) {
      if (mine != _generation) return;
      _emit(NodeStatus(phase: NodePhase.error, message: 'spawn failed: $e'));
      return;
    }
    // A stop landed while the spawn was in flight. The process is OURS and
    // nobody else holds a handle to it, so it goes now — leaving it would be
    // the stranded-child case one level up (audit XV-20), and publishing
    // anything about it would overwrite the `stopped` the person was told.
    if (mine != _generation) {
      process.kill();
      unawaited(process.exitCode);
      return;
    }
    _process = process;
    _adopted = false;

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
    // No generation check here on purpose: `_terminate` cancels this
    // subscription BEFORE it signals, so a superseded start's watcher is
    // already gone by the time the child dies. A guard was written here and
    // removed — nothing could redden it.
    _exitWatch = process.exitCode.asStream().listen((code) {
      exited = true;
      if (_current.phase != NodePhase.stopped) {
        _emit(
          NodeStatus(
            phase: NodePhase.error,
            message: 'node exited with code $code',
          ),
        );
      }
    });

    final deadline = DateTime.now().add(readinessTimeout);
    while (!exited && DateTime.now().isBefore(deadline)) {
      if (await readinessProbe()) {
        // Superseded while polling: the stop above already terminated what it
        // could and told the person the node is down.
        if (mine != _generation) return;
        _emit(const NodeStatus(phase: NodePhase.connected));
        return;
      }
      if (mine != _generation) return;
      await Future<void>.delayed(pollInterval);
    }
    if (mine != _generation) return;
    if (!exited && _current.phase != NodePhase.connected) {
      // KILL IT (audit XV-20). Giving up on the WAIT used to leave the child
      // RUNNING and unowned: it kept the admin socket and the listen port, and
      // the next `start()` — seeing no readiness — spawned a second one beside
      // it. Same shape as the stranded all-online node in XV-05: we stopped
      // watching and called that stopping.
      await _terminate();
      _emit(
        const NodeStatus(
          phase: NodePhase.error,
          message: 'node did not become ready before timeout',
        ),
      );
    }
  }

  /// Longest we wait for a killed child to actually go away before giving up on
  /// a clean reap. Short: the process was already told to die, and a caller
  /// blocked here is a UI that appears frozen.
  static const _exitGrace = Duration(seconds: 5);

  /// Stop the child and WAIT for it, so the caller's next `start()` cannot race
  /// a process that still holds the port.
  /// Signal the child and wait for it. Returns whether the exit was OBSERVED.
  ///
  /// The handle is dropped only when it was. It used to be cleared FIRST, so a
  /// child that did not die within the grace left nothing to signal again —
  /// and `stop()` announced `stopped` regardless, while a process still
  /// holding the admin socket and the listen port was running
  /// (report16 XV-06). The next `start()` then spawned beside it.
  Future<bool> _terminate() async {
    final process = _process;
    for (final d in _drains) {
      unawaited(d.cancel());
    }
    _drains = const [];
    await _exitWatch?.cancel();
    _exitWatch = null;
    if (process == null) {
      _process = null;
      return true;
    }
    process.kill();
    var exited = false;
    try {
      await process.exitCode.timeout(_exitGrace);
      exited = true;
    } catch (_) {
      // Did not die in time, or was already reaped by somebody else. Either
      // way this side has not seen it go.
    }
    if (exited) _process = null;
    return exited;
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
    // Records intent and nothing else — nothing reads `_economy` yet, and this
    // said the scaling was "driven through the transport
    // (VeilClient.setBackgroundMode)" as though something drove it.
    //
    // That lever is real: the plugin exposes `setBackgroundMode`, the FFI
    // exports `veil_set_background_mode`, and the daemon scales keepalives and
    // suppresses background maintenance from it. This app has never called it.
    // Its lifecycle observers cover the privacy screen and calls; neither
    // tells the node it went to the background, and the plugin has no observer
    // of its own. So the tier is not driven anywhere, by this method or by the
    // transport, and the comment made the gap look attended to (report17).
    _economy = economy;
  }

  bool get economyMode => _economy;

  @override
  Future<void> stop() async {
    // Claimed FIRST, so a start still working through its awaits knows it has
    // been superseded before it can publish anything (report17 XV17-M9).
    ++_generation;
    final adopted = _adopted;
    _adopted = false;
    // Awaits the exit (audit XV-20): this used to `kill()` and return
    // immediately, so a `start()` right after could spawn while the old process
    // still held the admin socket and the listen port — and the old handle was
    // already dropped, so nobody could stop it either.
    final exited = await _terminate();
    if (exited && adopted && await readinessProbe()) {
      // A node this controller adopted rather than spawned: there was no
      // handle to kill, and it is still answering. Reporting `stopped` here is
      // the same false claim as the signalled-but-not-seen-to-exit case below
      // — the node holds its admin socket and its listen port either way.
      _emit(
        const NodeStatus(
          phase: NodePhase.error,
          message:
              'this node was adopted, not started here, so it cannot be '
              'stopped from the app; it is still running',
        ),
      );
      return;
    }
    if (exited) {
      _emit(NodeStatus.stopped);
      return;
    }
    // Signalled and not seen to go. Saying `stopped` here is the claim that
    // made the next `start()` spawn beside a process still holding the admin
    // socket and the listen port.
    _emit(
      const NodeStatus(
        phase: NodePhase.error,
        message:
            'the node was signalled but has not been seen to exit; it may '
            'still hold its socket and port',
      ),
    );
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }
}
