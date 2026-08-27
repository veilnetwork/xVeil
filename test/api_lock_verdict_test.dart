import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/app_controller.dart';

/// A controller whose lock finishes only when the test says so.
class _GatedLock extends AppController {
  final gate = Completer<void>();
  var started = false;
  Object? failWith;

  @override
  AppState build() => const AppState(AppPhase.ready);

  /// What the real controller publishes after a lock: the legs that did not
  /// confirm they finished.
  List<String> verdict = const [];

  @override
  TeardownOutcome get lastTeardown => TeardownOutcome(verdict);

  @override
  Future<void> lock() async {
    started = true;
    await gate.future;
    final failure = failWith;
    if (failure != null) throw failure;
  }
}

void main() {
  /// The API's `locked: true` is the only statement in the system that the
  /// privacy boundary has closed, and the state layer used to schedule the
  /// lock and return at once. The response was written while the tunnel, the
  /// node and the container were all still up, and a failure landed in an
  /// unhandled async gap where nothing could report it.
  test('the API lock callback does not return before the lock does', () async {
    final gated = _GatedLock();
    final c = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => gated)],
    );
    addTearDown(c.dispose);

    var returned = false;
    final call = c.read(apiServerControllerProvider.notifier).lockForApi()
      ..then((_) => returned = true);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(gated.started, isTrue, reason: 'the lock was actually asked for');
    expect(
      returned,
      isFalse,
      reason: 'answering here is answering before anything was torn down',
    );

    gated.gate.complete();
    await call;
    expect(returned, isTrue);
  });

  test('a lock that fails reaches the API as a failure', () async {
    final gated = _GatedLock()..failWith = StateError('session would not stop');
    final c = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => gated)],
    );
    addTearDown(c.dispose);

    final call = c.read(apiServerControllerProvider.notifier).lockForApi();
    gated.gate.complete();
    await expectLater(
      call,
      throwsA(isA<StateError>()),
      reason: 'a swallowed failure is a 200 that lies',
    );
  });

  /// The lock that does not throw and is still not finished.
  ///
  /// `lock()` keeps going when the tunnel will not stop, on purpose: parking
  /// someone on an unlocked-looking screen because the OS did not answer is
  /// its own disclosure. So the API cannot learn about a surviving tunnel from
  /// an exception — it has to carry the verdict (report17 XV17-M14).
  test('the callback carries what the teardown could not confirm', () async {
    final gated = _GatedLock()
      ..verdict = const ['vpn', 'container-lock-unknown'];
    final c = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => gated)],
    );
    addTearDown(c.dispose);

    gated.gate.complete();
    final incomplete = await c
        .read(apiServerControllerProvider.notifier)
        .lockForApi();

    expect(
      incomplete,
      containsAll(<String>['vpn', 'container-lock-unknown']),
      reason: 'the API answers locked: true with no idea what is still up',
    );
  });

  test('CONTROL: a lock with nothing outstanding carries nothing', () async {
    final gated = _GatedLock();
    final c = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => gated)],
    );
    addTearDown(c.dispose);

    gated.gate.complete();
    expect(
      await c.read(apiServerControllerProvider.notifier).lockForApi(),
      isEmpty,
    );
  });
}
