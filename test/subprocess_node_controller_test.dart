import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/process_launcher.dart';
import 'package:xveil/data/node/subprocess_node_controller.dart';

class _FakeProcess implements NodeProcess {
  final _exit = Completer<int>();
  bool killed = false;

  void exitWith(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<String> get stdoutLines => const Stream.empty();
  @override
  Stream<String> get stderrLines => const Stream.empty();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill() {
    killed = true;
    exitWith(-15);
    return true;
  }
}

class _FakeLauncher implements ProcessLauncher {
  _FakeLauncher(this.process);
  final _FakeProcess process;
  int starts = 0;

  @override
  Future<NodeProcess> start(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    starts++;
    return process;
  }
}

/// First call (the adopt check) returns false so a spawn happens; every
/// subsequent poll returns true so the controller reaches connected.
ReadinessProbe _falseThenTrue() {
  var calls = 0;
  return () async => calls++ > 0;
}

SubprocessNodeController _make(_FakeLauncher launcher, ReadinessProbe probe) {
  return SubprocessNodeController(
    executable: 'veil-cli',
    args: const ['node', 'run'],
    readinessProbe: probe,
    launcher: launcher,
    readinessTimeout: const Duration(seconds: 2),
    pollInterval: const Duration(milliseconds: 1),
  );
}

void main() {
  test('spawns and reaches connected once the socket is ready', () async {
    final launcher = _FakeLauncher(_FakeProcess());
    final controller = _make(launcher, _falseThenTrue());

    final phases = <NodePhase>[];
    controller.status().listen((s) => phases.add(s.phase));

    await controller.start();
    // Broadcast events are delivered on later microtasks — flush before
    // asserting on the collected ordering.
    await Future<void>.delayed(Duration.zero);

    expect(launcher.starts, 1);
    expect(controller.current.phase, NodePhase.connected);
    expect(phases, contains(NodePhase.starting));
    expect(phases.last, NodePhase.connected);
  });

  test('adopts an already-running node without spawning', () async {
    final launcher = _FakeLauncher(_FakeProcess());
    final controller = _make(launcher, () async => true);

    await controller.start();

    expect(launcher.starts, 0);
    expect(controller.current.phase, NodePhase.connected);
  });

  test('reports error when the process exits before readiness', () async {
    final proc = _FakeProcess();
    final launcher = _FakeLauncher(proc);
    var calls = 0;
    // Never ready; exit the process on the first poll after the adopt check.
    final controller = _make(launcher, () async {
      if (calls++ == 1) proc.exitWith(1);
      return false;
    });

    await controller.start();

    expect(controller.current.phase, NodePhase.error);
    expect(controller.current.message, contains('exited'));
  });

  test('stop kills the spawned process and reports stopped', () async {
    final proc = _FakeProcess();
    final launcher = _FakeLauncher(proc);
    final controller = _make(launcher, _falseThenTrue());

    await controller.start();
    expect(launcher.starts, 1);
    await controller.stop();

    expect(proc.killed, isTrue);
    expect(controller.current.phase, NodePhase.stopped);
  });
}
