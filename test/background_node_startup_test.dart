import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/state/background_node_controller.dart';
import 'package:xveil/state/providers.dart';

void main() {
  test('an in-flight start completes before the final stop', () async {
    SharedPreferences.setMockInitialValues({'keep_node_background': true});
    final entered = Completer<void>(), release = Completer<void>();
    final calls = <String>[];
    final c = ProviderContainer(
      overrides: [
        backgroundServiceProvider.overrideWithValue(
          BackgroundServiceActions(
            start: () async {
              calls.add('starting');
              entered.complete();
              await release.future;
              calls.add('started');
            },
            stop: () async => calls.add('stopped'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final controller = c.read(backgroundNodeProvider.notifier);
    final boot = controller.applyIfNodeUp(nodeUp: true);
    await entered.future;
    final stop = controller.applyIfNodeUp(nodeUp: false);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['starting']);
    release.complete();
    await Future.wait([boot, stop]);
    expect(calls, ['starting', 'started', 'stopped']);
  });

  test(
    'boot waits for the persisted ON preference before applying the service',
    () async {
      SharedPreferences.setMockInitialValues({'keep_node_background': true});
      final load = Completer<SharedPreferences>();
      final calls = <bool>[];
      final c = ProviderContainer(
        overrides: [
          prefsProvider.overrideWith((ref) => load.future),
          backgroundServiceProvider.overrideWithValue(
            BackgroundServiceActions(
              start: () async => calls.add(true),
              stop: () async => calls.add(false),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final pending = c
          .read(backgroundNodeProvider.notifier)
          .applyIfNodeUp(nodeUp: true);
      await Future<void>.delayed(Duration.zero);
      expect(
        calls,
        isEmpty,
        reason: 'unread preferences must not be treated as OFF',
      );
      load.complete(await SharedPreferences.getInstance());
      await pending;
      expect(calls, [true]);
    },
  );

  test('teardown supersedes a boot parked on preferences', () async {
    SharedPreferences.setMockInitialValues({'keep_node_background': true});
    final load = Completer<SharedPreferences>();
    final calls = <bool>[];
    final c = ProviderContainer(
      overrides: [
        prefsProvider.overrideWith((ref) => load.future),
        backgroundServiceProvider.overrideWithValue(
          BackgroundServiceActions(
            start: () async => calls.add(true),
            stop: () async => calls.add(false),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final controller = c.read(backgroundNodeProvider.notifier);
    final boot = controller.applyIfNodeUp(nodeUp: true);
    final stop = controller.applyIfNodeUp(nodeUp: false);
    load.complete(await SharedPreferences.getInstance());
    await Future.wait([boot, stop]);
    expect(calls, [false]);
  });
}
