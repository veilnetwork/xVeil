import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/app_controller.dart';

class _Store extends QuickUnlockSecretStore {
  final values = <String, String>{};
  bool denyBio = false, refuseWrite = false, refuseDelete = false;
  int reads = 0;
  Completer<String?>? pendingBio;
  String _key(String key, bool bio) => '$bio:$key';
  @override
  Future<String?> read(String key, {bool biometric = false}) async {
    reads++;
    if (biometric && denyBio) throw StateError('OS authentication cancelled');
    if (biometric && pendingBio != null) return pendingBio!.future;
    return values[_key(key, biometric)];
  }

  @override
  Future<void> write(String key, String value, {bool biometric = false}) async {
    if (refuseWrite) throw StateError('OS write refused');
    values[_key(key, biometric)] = value;
  }

  @override
  Future<void> delete(String key, {bool biometric = false}) async {
    if (!refuseDelete) values.remove(_key(key, biometric));
  }

  @override
  Future<bool> contains(String key, {bool biometric = false}) async =>
      values.containsKey(_key(key, biometric));
}

class _Authentication extends LocalScreenAuthentication {
  @override
  Future<bool> authenticate(String reason) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store store;
  QuickUnlockVault vault([String scope = 'fixture']) =>
      QuickUnlockVault(store, scope, _Authentication());
  const password = 'strong fixture container password';
  setUp(() => store = _Store());

  test(
    'restart restores the original password through a device-bound pattern wrapper',
    () async {
      await vault().configure(
        password: password,
        grid: 3,
        nodes: [0, 1, 4, 8],
        system: false,
      );
      expect(store.values.values.join(), isNot(contains(password)));
      final restarted = vault();
      expect((await restarted.options()).grid, 3);
      expect(await restarted.openPattern([0, 1, 4, 7]), isNull);
      expect(await vault().openPattern([0, 1, 4, 8]), password);
      expect((await vault('other-profile').options()).enabled, isFalse);
    },
  );

  test(
    'failure budget survives process recreation and requires password after ten attempts',
    () async {
      await vault().configure(
        password: password,
        grid: 4,
        nodes: [0, 1, 5, 6],
        system: false,
      );
      final key = store.values.keys.single;
      final r = jsonDecode(store.values[key]!) as Map<String, dynamic>;
      r['tries'] = 9;
      r['after'] = 0;
      store.values[key] = jsonEncode(r);
      expect(await vault().openPattern([0, 1, 5, 7]), isNull);
      expect((await vault().options()).patternBlocked, isTrue);
      expect(await vault().openPattern([0, 1, 5, 6]), isNull);
      // Password confirmation in the unlocked settings permits explicit reset.
      await vault().configure(
        password: password,
        grid: 4,
        nodes: [0, 1, 5, 6],
        system: false,
      );
      expect(await vault().openPattern([0, 1, 5, 6]), password);
    },
  );

  test(
    'a different identity cannot inherit an old wrapper just because the grid matches',
    () async {
      await vault().configure(
        password: password,
        grid: 5,
        nodes: [0, 1, 6, 24],
        system: false,
      );
      await expectLater(
        vault().configure(
          password: 'different identity password',
          grid: 5,
          system: false,
        ),
        throwsStateError,
      );
      expect(await vault().openPattern([0, 1, 6, 24]), password);
    },
  );

  test(
    'copied wrapper is bound to the app profile, not merely to its pattern',
    () async {
      await vault('first').configure(
        password: password,
        grid: 3,
        nodes: [0, 1, 4, 8],
        system: false,
      );
      store.values['false:xveil.quick.v1.second'] =
          store.values['false:xveil.quick.v1.first']!;
      expect(await vault('second').openPattern([0, 1, 4, 8]), isNull);
    },
  );

  test(
    'OS authentication refusal never releases the stored biometric credential',
    () async {
      await vault().configure(password: password, system: true);
      expect((await vault().options()).system, isTrue);
      store.denyBio = true;
      await expectLater(vault().openSystem('test'), throwsStateError);
      store.denyBio = false;
      expect(await vault().openSystem('test'), password);
    },
  );

  test(
    'forget invalidates an already pending OS authentication and removes both records',
    () async {
      final active = vault();
      await active.configure(password: password, system: true);
      final credential = store.values.entries
          .singleWhere((e) => e.key.startsWith('true:'))
          .value;
      store.pendingBio = Completer<String?>();
      final pending = active.openSystem('test');
      await Future<void>.delayed(Duration.zero);
      await active.forget();
      store.pendingBio!.complete(credential);
      expect(await pending, isNull);
      expect(store.values, isEmpty);
    },
  );

  test('unverified write and lying delete report failure', () async {
    final active = vault();
    store.refuseWrite = true;
    await expectLater(
      active.configure(password: password, system: true),
      throwsStateError,
    );
    expect((await active.options()).enabled, isFalse);
    store.refuseWrite = false;
    await active.configure(password: password, system: true);
    store.refuseDelete = true;
    await expectLater(active.forget(), throwsStateError);
    expect(
      (jsonDecode(
            store.values.entries
                .singleWhere((e) => e.key.startsWith('false:'))
                .value,
          )
          as Map)['bioPending'],
      isTrue,
    );
    store.refuseDelete = false;
    await active.forget();
    expect(store.values, isEmpty);
  });

  test(
    'an identity change during enrollment removes the partial OS credential',
    () async {
      final active = vault();
      var current = true;
      store.pendingBio = Completer<String?>();
      final pending = active.configure(
        password: password,
        system: true,
        stillCurrent: () => current,
      );
      // Both stages reach the fake OS, but the protected read is held.
      for (
        var i = 0;
        i < 20 && !store.values.keys.any((k) => k.startsWith('true:'));
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      final value = store.values.entries
          .singleWhere((e) => e.key.startsWith('true:'))
          .value;
      current = false;
      store.pendingBio!.complete(value);
      await expectLater(pending, throwsStateError);
      expect(store.values, isEmpty);
    },
  );

  test(
    'start over revokes an actual saved credential and clears explicit consent',
    () async {
      SharedPreferences.setMockInitialValues({
        'onboarded': true,
        kStartupUnlockOptIn: true,
      });
      final active = vault();
      await active.configure(password: password, system: true);
      final c = ProviderContainer(
        overrides: [quickUnlockVaultProvider.overrideWithValue(active)],
      );
      addTearDown(c.dispose);
      final controller = c.read(appControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      await controller.startOver();
      expect(store.values, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getBool(kStartupUnlockOptIn),
        isNull,
      );
    },
  );

  test('wipe reports a saved OS credential it could not remove', () async {
    SharedPreferences.setMockInitialValues({
      'onboarded': true,
      kStartupUnlockOptIn: true,
    });
    final active = vault();
    await active.configure(password: password, system: true);
    store.refuseDelete = true;
    final c = ProviderContainer(
      overrides: [quickUnlockVaultProvider.overrideWithValue(active)],
    );
    addTearDown(c.dispose);
    final controller = c.read(appControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    final remaining = await controller.wipeContainers();
    expect(remaining, contains('quick-unlock'));
    expect(
      (await SharedPreferences.getInstance()).getBool(kStartupUnlockOptIn),
      isTrue,
    );
  });
  test('explicit re-enrollment replaces the old protected slot', () async {
    final active = vault();
    await active.configure(password: password, system: true);
    final old = store.values.keys.singleWhere((k) => k.startsWith('true:'));
    await active.configure(password: password, system: true);
    expect(store.values.keys, isNot(contains(old)));
    expect(store.values.keys.where((k) => k.startsWith('true:')), hasLength(1));
    expect(await active.openSystem('test'), password);
  });

  test(
    'default launch never reads or creates OS credentials without opt-in',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer(
        overrides: [quickUnlockVaultProvider.overrideWithValue(vault())],
      );
      addTearDown(c.dispose);
      expect(
        (await c.read(startupUnlockOptionsProvider.future)).enabled,
        isFalse,
      );
      expect(store.reads, 0);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kStartupUnlockOptIn, true);
      c.invalidate(startupUnlockOptionsProvider);
      await c.read(startupUnlockOptionsProvider.future);
      expect(store.reads, greaterThan(0));
    },
  );
}
