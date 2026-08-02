import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/process_launcher.dart';
import 'package:xveil/data/node/subprocess_node_controller.dart';

class _FakeProcess implements NodeProcess {
  _FakeProcess({this.dieOnKill = true, this.exitDelay = Duration.zero});

  /// When false, `kill()` is recorded but the process does NOT exit — the
  /// wedged child the exit grace exists for.
  final bool dieOnKill;

  /// How long the child takes to actually go away after `kill()`. Non-zero is
  /// what makes "did stop() WAIT?" observable: a stop that only fires the kill
  /// returns before this elapses.
  final Duration exitDelay;

  bool get hasExited => _exit.isCompleted;

  final _exit = Completer<int>();
  final stdout = StreamController<String>.broadcast();
  final stderr = StreamController<String>.broadcast();
  bool killed = false;

  void exitWith(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<String> get stdoutLines => stdout.stream;
  @override
  Stream<String> get stderrLines => stderr.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill() {
    killed = true;
    if (!dieOnKill) return true;
    if (exitDelay == Duration.zero) {
      exitWith(-15);
    } else {
      Future<void>.delayed(exitDelay, () => exitWith(-15));
    }
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

  group('the child process is owned, not merely watched', () {
    test('stdout and stderr are drained so the node cannot block on a full pipe',
        () async {
      // Audit XV-20. Nothing read the pipes, so once the OS buffer filled the
      // node BLOCKED on its next write and stopped doing anything — with no
      // error anywhere. How much it takes depends on log level and traffic,
      // which is what made it look intermittent.
      final proc = _FakeProcess();
      final launcher = _FakeLauncher(proc);
      final controller = _make(launcher, _falseThenTrue());
      await controller.start();

      expect(
        proc.stdout.hasListener,
        isTrue,
        reason: 'nothing reading stdout is a node that wedges on a full pipe',
      );
      expect(proc.stderr.hasListener, isTrue);

      // And the tail is bounded — a drain that accumulates is a leak wearing a
      // fix's clothes.
      for (var i = 0; i < 500; i++) {
        proc.stdout.add('line $i');
      }
      await Future<void>.delayed(Duration.zero);
      expect(controller.outputTail.length, lessThanOrEqualTo(200));
      expect(controller.outputTail.last, 'line 499');

      await controller.dispose();
    });

    test('a readiness timeout kills the child instead of abandoning it',
        () async {
      // Giving up on the WAIT used to leave the child RUNNING and unowned: it
      // kept the admin socket and the listen port, and the next start() — still
      // seeing no readiness — spawned a second one beside it.
      final proc = _FakeProcess();
      final launcher = _FakeLauncher(proc);
      final controller = SubprocessNodeController(
        executable: 'veil-cli',
        args: const ['node', 'run'],
        readinessProbe: () async => false, // never becomes ready
        launcher: launcher,
        readinessTimeout: const Duration(milliseconds: 30),
        pollInterval: const Duration(milliseconds: 1),
      );

      await controller.start();

      expect(controller.current.phase, NodePhase.error);
      expect(
        proc.killed,
        isTrue,
        reason: 'an unready child must be killed, not left holding the port',
      );
      await controller.dispose();
    });

    test('stop() waits for the child to actually exit', () async {
      // The child takes a moment to die, which is what makes the WAIT
      // observable: a stop that merely fires the kill returns first. Asserting
      // that `exitCode` eventually completes proves nothing — it completes
      // either way.
      final proc = _FakeProcess(exitDelay: const Duration(milliseconds: 150));
      final launcher = _FakeLauncher(proc);
      final controller = _make(launcher, _falseThenTrue());
      await controller.start();

      await controller.stop();

      expect(proc.killed, isTrue);
      expect(
        proc.hasExited,
        isTrue,
        reason: 'stop returned while the child still held the port',
      );
      expect(controller.current.phase, NodePhase.stopped);
    });

    test('a child that ignores the kill does not hang stop() forever', () async {
      // The grace exists so a wedged child cannot freeze the UI: the handle is
      // released either way, and waiting longer would not change the outcome.
      final proc = _FakeProcess(dieOnKill: false);
      final launcher = _FakeLauncher(proc);
      final controller = _make(launcher, _falseThenTrue());
      await controller.start();

      await controller.stop().timeout(
            const Duration(seconds: 8),
            onTimeout: () => fail('stop() hung on a child that will not die'),
          );
      expect(proc.killed, isTrue);
      expect(controller.current.phase, NodePhase.stopped);
    });
  });
}
