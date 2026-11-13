import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

void main() {
  test('legacy OS vault names remain byte-identical', () {
    expect(
      storageUnlockScope(
        'profile',
        '/synthetic/container',
        const LegacyStorageLocator(),
      ),
      sha256.convert(utf8.encode('profile:/synthetic/container')).toString(),
    );
  });
  test(
    'managed OS credentials are separated by ID, mode, root and profile',
    () {
      ManagedStorageLocator locator(
        String digit,
        StorageProtection protection,
      ) => ManagedStorageLocator(
        id: ManagedIdentityId(digit * 32),
        protection: protection,
      );
      final first = locator('a', StorageProtection.encrypted);
      final scopes = {
        storageUnlockScope(
          'profile',
          '/synthetic/root',
          const LegacyStorageLocator(),
        ),
        storageUnlockScope('profile', '/synthetic/root', first),
        storageUnlockScope('other', '/synthetic/root', first),
        storageUnlockScope('profile', '/synthetic/other', first),
        storageUnlockScope(
          'profile',
          '/synthetic/root',
          locator('b', StorageProtection.encrypted),
        ),
        storageUnlockScope(
          'profile',
          '/synthetic/root',
          locator('a', StorageProtection.unencrypted),
        ),
      };
      expect(scopes, hasLength(6));
      for (final value in scopes) {
        expect(value, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    },
  );
}
