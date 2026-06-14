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
      _emit(const NodeStatus(
        phase: NodePhase.error,
        message: 'node did not become ready before timeout',
      ));
    }
  }

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
    await _exitWatch?.cancel();
    _exitWatch = null;
    _process?.kill();
    _process = null;
    _emit(NodeStatus.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }
}
