import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/domain/screen_lock.dart';
import 'package:xveil/features/lock/pattern_pad.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';

import 'support/fake_setting_storage.dart';

class _Storage extends FakeSettingStorage {
  @override
  bool get isOpen => true;
}

class _Authentication extends LocalScreenAuthentication {
  bool answer = true;
  Completer<bool>? pending;
  int requests = 0;
  @override
  Future<bool> authenticate(String reason) async {
    requests++;
    return pending == null ? answer : pending!.future;
  }
}

void main() {
  late _Storage storage;
  late _Authentication auth;
  late ProviderContainer container;
  late ScreenLockController controller;

  setUp(() async {
    storage = _Storage();
    auth = _Authentication();
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        localScreenAuthenticationProvider.overrideWithValue(auth),
      ],
    );
    controller = container.read(screenLockProvider.notifier);
    await controller.reloadTimeout();
    controller.rememberPassword('strong container password');
    await controller.setTimeout(ScreenLockTimeout.immediately);
  });
  tearDown(() => container.dispose());

  Future<bool> configure({int? grid, List<int>? nodes, bool system = false}) =>
      controller.configureQuickUnlock(
        password: 'strong container password',
        grid: grid,
        nodes: nodes,
        system: system,
        reason: 'test',
      );

  for (final grid in [3, 4, 5]) {
    test('$grid grid persists and reopens only the correct sequence', () async {
      expect(
        await configure(grid: grid, nodes: [0, 1, grid + 1, grid * grid - 1]),
        isTrue,
      );
      final saved = storage.settings.values.join();
      expect(saved, isNot(contains('strong container password')));
      expect(saved, isNot(contains('$grid:0,1,')));
      controller.forgetSession();
      await controller.reloadTimeout();
      controller.rememberPassword('strong container password');
      controller.onLeftForeground();
      expect(
        controller.tryUnlockPattern([0, 1, grid + 1, grid * grid - 2]),
        isFalse,
      );
      expect(container.read(screenLockProvider).locked, isTrue);
      expect(
        controller.tryUnlockPattern([0, 1, grid + 1, grid * grid - 1]),
        isTrue,
      );
    });
  }

  test(
    'weak, repeated, out-of-grid patterns and wrong password are refused',
    () async {
      for (final nodes in [
        [0, 1, 2],
        [0, 1, 2, 2],
        [0, 1, 2, 9],
      ]) {
        expect(await configure(grid: 3, nodes: nodes), isFalse);
      }
      expect(
        await controller.configureQuickUnlock(
          password: 'wrong',
          grid: 3,
          nodes: [0, 1, 2, 5],
          system: false,
          reason: 'test',
        ),
        isFalse,
      );
      expect(storage.settings.keys.where((k) => k.contains('quick')), isEmpty);
    },
  );

  test(
    'pattern and password share the throttle and password remains usable',
    () async {
      await configure(grid: 3, nodes: [0, 1, 2, 5]);
      controller.onLeftForeground();
      controller.tryUnlockPattern([0, 1, 2, 3]);
      controller.tryUnlock('wrong');
      controller.tryUnlockPattern([0, 1, 2, 3]);
      expect(controller.throttleRemaining, greaterThan(Duration.zero));
      expect(controller.tryUnlock('strong container password'), isFalse);
      controller.debugAdvance(const Duration(seconds: 1));
      expect(controller.tryUnlock('strong container password'), isTrue);
    },
  );

  test('cancelled system enrollment cannot turn the setting on', () async {
    auth.answer = false;
    expect(await configure(system: true), isFalse);
    expect(container.read(screenLockProvider).systemAuthentication, isFalse);
  });

  test(
    'system auth success lifts this cover, never a subsequent session',
    () async {
      await configure(system: true);
      controller.onLeftForeground();
      auth.pending = Completer<bool>();
      final result = controller.tryUnlockSystem('test');
      expect(await controller.tryUnlockSystem('test'), isFalse);
      controller.forgetSession();
      await controller.reloadTimeout();
      controller.rememberPassword('another password');
      controller.onLeftForeground();
      auth.pending!.complete(true);
      expect(await result, isFalse);
      expect(container.read(screenLockProvider).locked, isTrue);
      expect(controller.tryUnlock('another password'), isTrue);
    },
  );

  test(
    'system authentication is opt in and can be removed without losing pattern',
    () async {
      await configure(grid: 4, nodes: [0, 1, 5, 6], system: true);
      await configure(grid: 4); // keep existing pattern while removing OS auth
      expect(container.read(screenLockProvider).systemAuthentication, isFalse);
      controller.onLeftForeground();
      expect(await controller.tryUnlockSystem('test'), isFalse);
      expect(controller.tryUnlockPattern([0, 1, 5, 6]), isTrue);
    },
  );

  testWidgets('pad accepts taps and drag crossing nodes without duplicates', (
    tester,
  ) async {
    List<int> nodes = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: PatternPad(grid: 3, onChanged: (value) => nodes = value),
        ),
      ),
    );
    final a = tester.getCenter(find.byKey(const ValueKey('pattern-node-0')));
    final c = tester.getCenter(find.byKey(const ValueKey('pattern-node-2')));
    final gesture = await tester.startGesture(a);
    await gesture.moveTo(c);
    await gesture.up();
    await tester.pump();
    expect(nodes, [0, 1, 2]);
    await tester.tap(find.byKey(const ValueKey('pattern-node-2')));
    await tester.tap(find.byKey(const ValueKey('pattern-node-5')));
    expect(nodes, [0, 1, 2, 5]);
  });
}
