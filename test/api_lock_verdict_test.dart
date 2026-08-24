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
}
