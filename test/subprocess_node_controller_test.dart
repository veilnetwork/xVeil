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
  int kills = 0;

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
    kills++;
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

/// A launcher whose `start` PARKS until released — the window a stop lands in.
///
/// The spawn is an await like any other, and a `stop()` arriving inside it
/// finds no handle yet.
class _ParkedLauncher implements ProcessLauncher {
  _ParkedLauncher(this.process);
  final _FakeProcess process;
  int starts = 0;
  final _asked = Completer<void>();
  final _release = Completer<void>();

  /// Resolves once `start()` is actually inside the spawn.
  Future<void> get spawnRequested => _asked.future;
  void release() => _release.complete();

  @override
  Future<NodeProcess> start(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    starts++;
    _asked.complete();
    await _release.future;
    return process;
  }
}

/// A probe that refuses the adopt check, then PARKS on the first readiness
/// poll — the other window a stop lands in, with the handle already stored.
class _ParkedProbe {
  int calls = 0;
  final _asked = Completer<void>();
  final _answer = Completer<bool>();

  Future<void> get polling => _asked.future;
  void release(bool ready) => _answer.complete(ready);

  Future<bool> call() async {
    if (calls++ == 0) return false;
    if (!_asked.isCompleted) _asked.complete();
    return _answer.future;
  }
}

/// First call (the adopt check) returns false so a spawn happens; every
/// subsequent poll returns true so the controller reaches connected.
ReadinessProbe _falseThenTrue() {
  var calls = 0;
  return () async => calls++ > 0;
}

SubprocessNodeController _make(ProcessLauncher launcher, ReadinessProbe probe) {
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
    test(
      'stdout and stderr are drained so the node cannot block on a full pipe',
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
      },
    );

    test(
      'a readiness timeout kills the child instead of abandoning it',
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
      },
    );

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

    test(
      'a child that ignores the kill does not hang stop() forever',
      () async {
        // The grace exists so a wedged child cannot freeze the UI. That part is
        // unchanged; what is not is what happens afterwards.
        final proc = _FakeProcess(dieOnKill: false);
        final launcher = _FakeLauncher(proc);
        final controller = _make(launcher, _falseThenTrue());
        await controller.start();

        await controller.stop().timeout(
          const Duration(seconds: 8),
          onTimeout: () => fail('stop() hung on a child that will not die'),
        );
        expect(proc.killed, isTrue);
      },
    );

    test('and it is NOT reported as stopped', () async {
      // It used to be. The handle was released whether or not the child was
      // seen to go, and `stopped` was announced regardless — while a process
      // still holding the admin socket and the listen port was running
      // (report16 XV-06). The next `start()` then spawned beside it.
      final proc = _FakeProcess(dieOnKill: false);
      final controller = _make(_FakeLauncher(proc), _falseThenTrue());
      await controller.start();

      await controller.stop();

      expect(controller.current.phase, isNot(NodePhase.stopped));
      expect(controller.current.message, contains('has not been seen to exit'));
    });

    test('and a second stop can still signal it', () async {
      // The point of keeping the handle: releasing the PID meant nobody could
      // reach the process again, and the only cure was killing the app.
      final proc = _FakeProcess(dieOnKill: false);
      final controller = _make(_FakeLauncher(proc), _falseThenTrue());
      await controller.start();
      await controller.stop();
      expect(proc.kills, 1);

      await controller.stop();

      expect(proc.kills, 2, reason: 'the second stop had nothing to signal');
    });

    test('CONTROL: a child that DOES go is stopped, and let go of', () async {
      // Vacuity guard: keeping the handle always would leave every clean stop
      // reporting an error and signalling a corpse on the next one.
      final proc = _FakeProcess();
      final controller = _make(_FakeLauncher(proc), _falseThenTrue());
      await controller.start();

      await controller.stop();
      expect(controller.current.phase, NodePhase.stopped);

      await controller.stop();
      expect(proc.kills, 1, reason: 'it signalled a process already gone');
    });
  });

  group('a stop lands in the middle of a start (report17 XV17-M9)', () {
    // A start is a sequence of awaits — the spawn, then a readiness poll that
    // can run for the whole timeout. A stop arriving inside it used to find
    // `_process` still null, report `stopped`, and leave the start running:
    // the start then finished, published `connected`, and the person was
    // looking at a node they had just switched off.

    test('stop during the SPAWN wins, and the late child is killed', () async {
      final proc = _FakeProcess();
      final launcher = _ParkedLauncher(proc);
      final controller = _make(launcher, _falseThenTrue());

      final starting = controller.start();
      await launcher.spawnRequested;

      await controller.stop();
      expect(controller.current.phase, NodePhase.stopped);

      launcher.release();
      await starting;

      expect(
        controller.current.phase,
        NodePhase.stopped,
        reason: 'the superseded start published over the stop',
      );
      expect(
        proc.killed,
        isTrue,
        reason: 'the process it spawned outlived the stop, unowned',
      );
    });

    test('stop during the readiness POLL wins', () async {
      // Here the handle IS stored, so the stop kills what it can; what must
      // not happen is the poll coming back afterwards and calling it up.
      final proc = _FakeProcess();
      final probe = _ParkedProbe();
      final controller = _make(_FakeLauncher(proc), probe.call);

      final starting = controller.start();
      await probe.polling;

      await controller.stop();
      expect(controller.current.phase, NodePhase.stopped);
      expect(proc.killed, isTrue);

      probe.release(true);
      await starting;

      expect(
        controller.current.phase,
        NodePhase.stopped,
        reason: 'a node the person stopped was reported connected',
      );
    });
  });

  group('a node that was ADOPTED, not spawned (report17 XV17-M9)', () {
    test('cannot be stopped from here, and is not called stopped', () async {
      // Adoption leaves no handle. `_terminate` has nothing to kill, so it
      // reported a clean exit — for a node that goes on holding the admin
      // socket and the listen port.
      final launcher = _FakeLauncher(_FakeProcess());
      final controller = _make(launcher, () async => true);

      await controller.start();
      expect(launcher.starts, 0, reason: 'it spawned instead of adopting');

      await controller.stop();

      expect(
        controller.current.phase,
        isNot(NodePhase.stopped),
        reason: 'a node that is still answering was reported stopped',
      );
      expect(controller.current.message, contains('still running'));
    });

    test('CONTROL: an adopted node that IS gone reports stopped', () async {
      // Vacuity guard: refusing on every adopted node would leave a node that
      // went away on its own permanently stuck in an error.
      var calls = 0;
      final controller = _make(
        _FakeLauncher(_FakeProcess()),
        () async => calls++ == 0,
      );

      await controller.start();
      expect(controller.current.phase, NodePhase.connected);

      await controller.stop();

      expect(controller.current.phase, NodePhase.stopped);
    });

    test('CONTROL: a node spawned HERE still stops cleanly', () async {
      // And the adopted flag must not survive into the next spawn.
      final proc = _FakeProcess();
      final controller = _make(_FakeLauncher(proc), _falseThenTrue());

      await controller.start();
      await controller.stop();

      expect(controller.current.phase, NodePhase.stopped);
      expect(proc.killed, isTrue);
    });
  });
}
