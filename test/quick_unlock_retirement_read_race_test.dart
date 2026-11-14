import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'support/retirement_secret_store.dart';

/// Holds exactly one metadata read with its pre-retirement answer. All removal
/// work proceeds normally; no clocks, real credentials or OS authentication.
class _ReadGate extends RetirementSecretStore {
  int? holdMetadataRead;
  int metadataReads = 0, authenticatedReads = 0;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<String?> read(String key, {bool biometric = false}) async {
    final value = await super.read(key, biometric: biometric);
    if (!biometric && ++metadataReads == holdMetadataRead) {
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<String?> readAuthenticated(
    String key,
    String reason,
    LocalScreenAuthentication authentication,
  ) {
    authenticatedReads++;
    return read(key, biometric: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = 'a' * 64;
  Future<(_ReadGate, QuickUnlockVault)> fixture(int held) async {
    final store = _ReadGate();
    final vault = QuickUnlockVault(store, scope, RetirementAuthentication());
    await vault.configure(password: 'only synthetic input', system: true);
    store.metadataReads = 0;
    store.holdMetadataRead = held;
    return (store, vault);
  }

  Future<void> retire(_ReadGate store) => QuickUnlockRetirement(
    store,
    StorageUnlockScopes([scope]),
    RetirementAuthentication(),
  ).retire();

  for (final permanent in [false, true]) {
    final policy = permanent ? 'retirement' : 'ordinary forget';
    test('$policy: late options cannot restore saved-entry controls', () async {
      final (store, vault) = await fixture(1);
      final options = vault.options();
      await store.entered.future;
      try {
        await (permanent ? retire(store) : vault.forget());
      } finally {
        store.release.complete();
      }
      expect((await options).enabled, isFalse);
      expect(store.values, isEmpty);
    });

    test(
      '$policy: initial metadata cannot start a late biometric prompt',
      () async {
        final (store, vault) = await fixture(1);
        final opening = vault.openSystem('synthetic reason');
        await store.entered.future;
        try {
          await (permanent ? retire(store) : vault.forget());
        } finally {
          store.release.complete();
        }
        expect(await opening, isNull);
        expect(store.authenticatedReads, 0);
      },
    );

    test('$policy: final metadata cannot return a stale password', () async {
      final (store, vault) = await fixture(2);
      final opening = vault.openSystem('synthetic reason');
      await store.entered.future;
      try {
        await (permanent ? retire(store) : vault.forget());
      } finally {
        store.release.complete();
      }
      expect(await opening, isNull);
      expect(store.authenticatedReads, 1);
      expect(store.values, isEmpty);
    });
  }
}
