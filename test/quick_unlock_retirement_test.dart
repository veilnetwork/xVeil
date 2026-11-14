import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'support/retirement_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RetirementSecretStore store;
  late RetirementAuthentication auth;
  final first = 'a' * 64, second = 'b' * 64, unrelated = 'c' * 64;
  QuickUnlockVault vault(String scope) => QuickUnlockVault(store, scope, auth);
  setUp(() {
    store = RetirementSecretStore();
    auth = RetirementAuthentication();
  });
  test(
    'a refusing scope cannot stop retirement of all other known scopes',
    () async {
      for (final scope in [first, second, unrelated]) {
        await vault(
          scope,
        ).configure(password: 'synthetic $scope', system: true);
      }
      store.deniedScopes.add(first);
      final retirement = QuickUnlockRetirement(
        store,
        StorageUnlockScopes([first, second]),
        auth,
      );
      await expectLater(
        retirement.retire(),
        throwsA(
          isA<QuickUnlockRetirementFailure>().having(
            (e) => e.toString(),
            'safe diagnostic',
            isNot(contains(first)),
          ),
        ),
      );
      expect(store.values.keys.any((k) => k.contains(first)), isTrue);
      expect(store.values.keys.any((k) => k.contains(second)), isFalse);
      expect(
        await vault(unrelated).openSystem('fixture'),
        'synthetic $unrelated',
      );
      for (final scope in [first, second]) {
        await expectLater(
          vault(scope).configure(password: 'late synthetic', system: true),
          throwsStateError,
        );
      }
      store.deniedScopes.clear();
      await retirement.retire();
      expect(
        store.values.keys.any((k) => k.contains(first) || k.contains(second)),
        isFalse,
      );
      final reads = store.reads;
      for (final scope in [first, second]) {
        expect((await vault(scope).options()).enabled, isFalse);
        expect(await vault(scope).openSystem('fixture'), isNull);
        expect(await vault(scope).openPattern([0, 1, 4, 8]), isNull);
      }
      expect(store.reads, reads);
    },
  );
  test(
    'retirement seals every scope before waiting and joins the accepted old write',
    () async {
      store.heldScope = first;
      store.writeEntered = Completer<void>();
      store.writeRelease = Completer<void>();
      final old = vault(first);
      final enrollment = old
          .configure(password: 'held synthetic', system: true)
          .then<Object?>((_) => null, onError: (Object e) => e);
      await store.writeEntered!.future;
      final retirement = QuickUnlockRetirement(
        store,
        StorageUnlockScopes([first, second]),
        auth,
      );
      var completed = false;
      final pending = retirement.retire().then((_) => completed = true);
      final joined = retirement.retire();
      try {
        await Future<void>(() {});
        expect(completed, isFalse);
        await expectLater(
          vault(first).configure(password: 'late synthetic', system: true),
          throwsStateError,
        );
        await expectLater(
          vault(second).configure(password: 'late synthetic', system: true),
          throwsStateError,
        );
      } finally {
        store.writeRelease!.complete();
      }
      expect(await enrollment, isA<StateError>());
      await pending;
      await joined;
      expect(store.values, isEmpty);
      await expectLater(
        old.configure(password: 'old wrapper synthetic', system: true),
        throwsStateError,
      );
    },
  );
  test(
    'unreadable cleanup metadata remains and blocks successful retirement',
    () async {
      final key = 'false:xveil.quick.v1.$first';
      store.values[key] = jsonEncode({'v': 99, 'unknown': 'synthetic'});
      final retirement = QuickUnlockRetirement(
        store,
        StorageUnlockScopes([first]),
        auth,
      );
      final before = Map.of(store.values);
      await expectLater(
        retirement.retire(),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(store.values, before);
    },
  );
  test('read-only retirement detects a reappearing biometric record', () async {
    await vault(first).configure(password: 'synthetic retired', system: true);
    await vault(
      unrelated,
    ).configure(password: 'synthetic unrelated', system: true);
    final key = store.values.keys.singleWhere(
      (key) => key.startsWith('true:') && key.contains(first),
    );
    final saved = store.values[key]!;
    final retirement = QuickUnlockRetirement(
      store,
      StorageUnlockScopes([first]),
      auth,
    );
    await retirement.retire();
    expect(store.values.keys.any((key) => key.contains(first)), isFalse);
    store.values[key] = saved;
    final before = Map.of(store.values);
    await expectLater(
      retirement.verifyAbsent(),
      throwsA(isA<QuickUnlockRetirementFailure>()),
    );
    expect(
      store.values,
      before,
      reason: 'absence verification must not delete',
    );
    store.values.remove(key); // The fixture, not the verifier, resolves this.
    await retirement.verifyAbsent();
    expect(await vault(unrelated).openSystem('fixture'), 'synthetic unrelated');
  });

  test(
    'ordinary forget can explicitly re-enroll; another backend is independent',
    () async {
      final ordinary = vault(first);
      await ordinary.configure(password: 'synthetic old', system: true);
      await ordinary.forget();
      await ordinary.configure(password: 'synthetic fresh', system: true);
      final retirement = QuickUnlockRetirement(
        store,
        StorageUnlockScopes([first]),
        auth,
      );
      await retirement.retire();
      final other = RetirementSecretStore();
      final independent = QuickUnlockVault(other, first, auth);
      await independent.configure(
        password: 'independent synthetic',
        system: true,
      );
      expect(await independent.openSystem('fixture'), 'independent synthetic');
    },
  );
}
