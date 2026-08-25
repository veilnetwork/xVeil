import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/veil_stack.dart';

/// `RealVeilStack.start` starts a node and then has several more things to get
/// right. Two of those exits used to walk away from a node that was already
/// running: a phase that never reached `connected` threw with nothing stopped,
/// and a failing bootstrap invite skipped both the node and the transport.
///
/// A node nobody holds keeps its sockets and its runtime directory, and on the
/// embedded path it is a runtime still inside an app that has given up on it
/// (report12 X-L5).
class _StartsButNeverConnects implements NodeController {
  int starts = 0;
  int stops = 0;

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> setEconomyMode(bool economy) async {}

  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.starting);

  @override
  Stream<NodeStatus> status() => Stream.value(current);
}

void main() {
  tearDown(() => RealVeilStack.debugControllerFactory = null);

  test('a node that starts and never connects is stopped again', () async {
    final controller = _StartsButNeverConnects();
    RealVeilStack.debugControllerFactory = () => controller;

    await expectLater(
      RealVeilStack.start(
        veilCliPath: '/nonexistent/veil-cli',
        configPath: '/nonexistent/config.toml',
        appSocketPath: '/nonexistent/app.sock',
      ),
      throwsA(isA<StateError>()),
      reason: 'the caller must still learn the boot failed',
    );

    expect(controller.starts, 1, reason: 'the fixture must have started it');
    expect(
      controller.stops,
      1,
      reason:
          'it was RUNNING when the boot gave up — leaving it there keeps its '
          'sockets and its runtime directory for the life of the process',
    );
  });
}
