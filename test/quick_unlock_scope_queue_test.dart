import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

class _Auth extends LocalScreenAuthentication {
  @override
  Future<bool> authenticate(String reason) async => true;
}

class _Store extends QuickUnlockSecretStore {
  final values = <String, String>{};
  final entered = Completer<void>(), release = Completer<void>();
  String key(String key, bool bio) => '$bio:$key';
  @override
  Future<String?> read(String key, {bool biometric = false}) async =>
      values[this.key(key, biometric)];
  @override
  Future<String?> readAuthenticated(
    String key,
    String reason,
    LocalScreenAuthentication authentication,
  ) => read(key, biometric: true);
  @override
  Future<void> write(String key, String value, {bool biometric = false}) async {
    if (biometric && value.contains('held synthetic password')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    values[this.key(key, biometric)] = value;
  }

  @override
  Future<void> delete(String key, {bool biometric = false}) async {
    values.remove(this.key(key, biometric));
  }

  @override
  Future<bool> contains(String key, {bool biometric = false}) async =>
      values.containsKey(this.key(key, biometric));
}

Future<Object?> outcome(Future<void> task) =>
    task.then<Object?>((_) => null, onError: (Object e) => e);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a replacement vault must join accepted enrollment before verified forget',
    () async {
      final store = _Store(), auth = _Auth();
      final old = QuickUnlockVault(store, 'same synthetic scope', auth);
      final replacement = QuickUnlockVault(store, 'same synthetic scope', auth);
      final enrollment = outcome(
        old.configure(password: 'held synthetic password', system: true),
      );
      await store.entered.future;
      var forgotten = false;
      final forgetting = replacement.forget().then((_) => forgotten = true);
      bool premature;
      try {
        // All fake OS work is immediate except the explicitly held write.
        await Future<void>(() {});
        premature = forgotten;
      } finally {
        store.release.complete();
      }
      final failure = await enrollment;
      await forgetting;
      expect(
        premature,
        isFalse,
        reason:
            'a new wrapper cannot declare OS absence before an accepted old write settles',
      );
      expect(failure, isA<StateError>());
      expect(store.values, isEmpty);
    },
  );
  test(
    'replacement configuration serializes and cannot leave an older biometric slot',
    () async {
      final store = _Store(), auth = _Auth();
      final old = QuickUnlockVault(store, 'same synthetic scope', auth);
      final replacement = QuickUnlockVault(store, 'same synthetic scope', auth);
      final first = outcome(
        old.configure(password: 'held synthetic password', system: true),
      );
      await store.entered.future;
      var latestDone = false;
      final latest = outcome(
        replacement
            .configure(password: 'new synthetic password', system: true)
            .then((_) => latestDone = true),
      );
      bool premature;
      try {
        await Future<void>(() {});
        premature = latestDone;
      } finally {
        store.release.complete();
      }
      final firstFailure = await first;
      expect(await latest, isNull);
      expect(premature, isFalse);
      expect(firstFailure, isA<StateError>());
      final slots = store.values.entries
          .where((e) => e.key.startsWith('true:'))
          .toList();
      expect(slots, hasLength(1));
      expect(
        (jsonDecode(slots.single.value) as Map)['password'],
        'new synthetic password',
      );
      expect(
        await replacement.openSystem('synthetic'),
        'new synthetic password',
      );
    },
  );
  test(
    'other scopes and independent fake backends are not serialized by a held enrollment',
    () async {
      final held = _Store(), other = _Store(), auth = _Auth();
      final old = QuickUnlockVault(held, 'scope A', auth);
      final pending = outcome(
        old.configure(password: 'held synthetic password', system: true),
      );
      await held.entered.future;
      try {
        await QuickUnlockVault(
          held,
          'scope B',
          auth,
        ).configure(password: 'unrelated synthetic', system: true);
        await QuickUnlockVault(
          other,
          'scope A',
          auth,
        ).configure(password: 'independent synthetic', system: true);
        expect(
          await QuickUnlockVault(
            other,
            'scope A',
            auth,
          ).openSystem('synthetic'),
          'independent synthetic',
        );
      } finally {
        held.release.complete();
        await pending;
      }
    },
  );
}
