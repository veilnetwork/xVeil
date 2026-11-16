import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'support/retirement_secret_store.dart';

// Android public metadata shares one checked backing file across scopes. A
// second editor while a cleanup write is pending invalidates its disk/cache
// witness; the backend must refuse rather than discard an unrelated record.
class _SharedMetadataStore extends RetirementSecretStore {
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = false, writing = false;
  int overlaps = 0;

  @override
  Future<void> write(String key, String value, {bool biometric = false}) async {
    if (!armed || biometric) {
      return super.write(key, value, biometric: biometric);
    }
    if (writing) {
      overlaps++;
      throw StateError('Shared metadata editor is still pending');
    }
    writing = true;
    try {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      await super.write(key, value, biometric: biometric);
    } finally {
      writing = false;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('multi-scope retirement respects a shared metadata writer', () async {
    final store = _SharedMetadataStore();
    final auth = RetirementAuthentication();
    final first = 'a' * 64, second = 'b' * 64, foreign = 'c' * 64;
    for (final scope in [first, second, foreign]) {
      await QuickUnlockVault(
        store,
        scope,
        auth,
      ).configure(password: 'synthetic fixture $scope', system: true);
    }
    store.armed = true;
    final owner = QuickUnlockRetirement(
      store,
      StorageUnlockScopes([first, second]),
      auth,
    );
    final result = owner.retire().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await store.entered.future;
    // Both scopes must already reject enrollment while the shared write waits.
    for (final scope in [first, second]) {
      await expectLater(
        QuickUnlockVault(
          store,
          scope,
          auth,
        ).configure(password: 'late synthetic fixture', system: true),
        throwsStateError,
      );
    }
    store.release.complete();
    expect(await result, isNull);
    expect(store.overlaps, 0);
    await owner.verifyAbsent();
    expect(
      store.values.keys.any(
        (key) => key.contains(first) || key.contains(second),
      ),
      isFalse,
    );
    expect(
      await QuickUnlockVault(store, foreign, auth).openSystem('fixture'),
      'synthetic fixture $foreign',
    );
  });
}
