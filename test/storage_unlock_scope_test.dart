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

  test(
    'profile retirement derives every public scope and exactly one legacy scope',
    () {
      final identities = [
        for (final (id, mode) in [
          ('a', StorageProtection.encrypted),
          ('b', StorageProtection.unencrypted),
        ])
          ManagedStorageLocator(
            id: ManagedIdentityId(id * 32),
            protection: mode,
          ),
      ];
      final scopes = StorageUnlockScopes.forProfile(
        profile: 'fixture profile',
        legacyPath: '/fixture/legacy',
        managedPath: '/fixture/managed',
        identities: identities,
      );
      expect(scopes.ids.toSet(), {
        storageUnlockScope(
          'fixture profile',
          '/fixture/legacy',
          const LegacyStorageLocator(),
        ),
        for (final id in identities)
          storageUnlockScope('fixture profile', '/fixture/managed', id),
      });
      expect(scopes.ids, hasLength(3));
      expect(jsonEncode(scopes.ids), isNot(contains('/fixture')));
      final hiddenOnly = StorageUnlockScopes.forProfile(
        profile: 'fixture profile',
        legacyPath: '/fixture/legacy',
        managedPath: '/fixture/managed',
        identities: [],
      );
      expect(hiddenOnly.ids, [scopes.ids.first]);
    },
  );
  test(
    'scope sets snapshot input and reject malformed, duplicated or excessive entries',
    () {
      final input = ['a' * 64];
      final set = StorageUnlockScopes(input);
      input[0] = 'b' * 64;
      expect(set.ids, ['a' * 64]);
      expect(() => set.ids.add('b' * 64), throwsUnsupportedError);
      for (final bad in <List<String>>[
        [],
        [''],
        ['A' * 64],
        ['a' * 63],
        ['../fixture'],
        ['a' * 64, 'a' * 64],
        List.generate(130, (i) => i.toRadixString(16).padLeft(64, '0')),
      ]) {
        expect(() => StorageUnlockScopes(bad), throwsFormatException);
      }
      final excessive = List.generate(
        129,
        (i) => ManagedStorageLocator(
          id: ManagedIdentityId(i.toRadixString(16).padLeft(32, '0')),
          protection: StorageProtection.encrypted,
        ),
      );
      expect(
        () => StorageUnlockScopes.forProfile(
          profile: 'fixture',
          legacyPath: '/fixture',
          managedPath: '/fixture/managed',
          identities: excessive,
        ),
        throwsFormatException,
      );
    },
  );
}
