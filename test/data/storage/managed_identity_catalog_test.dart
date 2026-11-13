import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/storage_protection.dart';

void main() {
  const first = '11111111111111111111111111111111';
  const second = '22222222222222222222222222222222';

  test(
    'mixed visible modes retain locators and disclose only mode and count',
    () {
      final catalog = ManagedIdentityCatalog([
        ManagedIdentityEntry(
          id: ManagedIdentityId(first),
          protection: StorageProtection.defaultForNewIdentity,
        ),
        ManagedIdentityEntry(
          id: ManagedIdentityId(second),
          protection: StorageProtection.unencrypted,
        ),
      ]);
      final encoded = catalog.encode();
      expect(jsonDecode(encoded), {
        'version': 1,
        'identities': [
          {'id': first, 'protection': 'encrypted'},
          {'id': second, 'protection': 'unencrypted'},
        ],
      });
      final reopened = ManagedIdentityCatalog.decode(encoded);
      expect(reopened.identities.map((e) => e.id.value), [first, second]);
      expect(reopened.identities.map((e) => e.protection), [
        StorageProtection.encrypted,
        StorageProtection.unencrypted,
      ]);
    },
  );

  test('hidden spaces cannot enter the catalog through either boundary', () {
    expect(
      () => ManagedIdentityEntry(
        id: ManagedIdentityId(first),
        protection: StorageProtection.hidden,
      ),
      throwsArgumentError,
    );
    expect(
      () => ManagedIdentityCatalog.decode(
        jsonEncode({
          'version': 1,
          'identities': [
            {'id': first, 'protection': 'hidden'},
          ],
        }),
      ),
      throwsFormatException,
    );
  });

  test('extra fields, duplicate locators and future schemas fail closed', () {
    final valid = {
      'version': 1,
      'identities': [
        {'id': first, 'protection': 'encrypted'},
      ],
    };
    for (final invalid in [
      {...valid, 'version': 2},
      {...valid, 'password': 'fixture-only'},
      {
        ...valid,
        'identities': [
          {'id': first, 'protection': 'encrypted', 'keys': 'fixture-only'},
        ],
      },
      {
        ...valid,
        'identities': [
          {'id': first, 'protection': 'encrypted'},
          {'id': first, 'protection': 'unencrypted'},
        ],
      },
    ]) {
      expect(
        () => ManagedIdentityCatalog.decode(jsonEncode(invalid)),
        throwsFormatException,
      );
    }
  });

  test(
    'a catalog cannot select a hidden, sibling or absolute storage path',
    () {
      for (final id in [
        '../xveil.store',
        '/xveil.store',
        '..\\xveil.store',
        '$first/../../xveil.store',
        '%2e%2e%2fxveil.store',
        '${first}0',
        '$first\n',
        'A' * 32,
        '',
      ]) {
        expect(() => ManagedIdentityId(id), throwsFormatException);
      }
      final root = Directory.systemTemp.uri.resolve('managed-layout-fixture/');
      final layout = ManagedIdentityLayout(Directory.fromUri(root).path);
      final a = ManagedIdentityId(first);
      final b = ManagedIdentityId(second);
      expect(
        File(layout.dataPath(a)).uri,
        root.resolve('identities/$first/data.store'),
      );
      expect(
        Directory(layout.blobDirectory(a)).uri,
        root.resolve('identities/$first/blobs/'),
      );
      expect(
        File(layout.catalogPath).uri,
        root.resolve('identities/catalog.sqlite3'),
      );
      expect(
        File(layout.leasePath(a)).uri,
        root.resolve('identities/$first/identity.meta'),
      );
      expect(layout.leasePath(a), isNot(layout.leasePath(b)));
      expect(
        File(layout.leaseLockPath(a)).uri,
        root.resolve('identities/$first/identity.meta.lock'),
      );
      expect(layout.leaseLockPath(a), isNot(layout.leaseLockPath(b)));
      final owned = [
        layout.dataPath(a),
        layout.keyboxPath(a),
        layout.contentPath(a),
        layout.maintenancePath(a),
      ];
      expect(owned.map((path) => File(path).uri), [
        for (final name in [
          'data.store',
          'keybox.hv',
          'content.hv',
          'maintenance.hv',
        ])
          root.resolve('identities/$first/$name'),
      ]);
      expect(owned.toSet().length, 4);
      expect(layout.keyboxPath(a), isNot(layout.keyboxPath(b)));
      expect(layout.contentPath(a), isNot(layout.contentPath(b)));
      expect(layout.maintenancePath(a), isNot(layout.maintenancePath(b)));
      expect(layout.dataPath(a), isNot(layout.dataPath(b)));
    },
  );

  test('hostile catalog sizes are rejected before any storage is selected', () {
    expect(
      () => ManagedIdentityCatalog.decode(
        ' ' * (ManagedIdentityCatalog.maxEncodedBytes + 1),
      ),
      throwsFormatException,
    );
    expect(
      () => ManagedIdentityCatalog.decode(
        jsonEncode({
          'version': 1,
          'identities': List.generate(
            ManagedIdentityCatalog.maxIdentities + 1,
            (i) => {
              'id': i.toRadixString(16).padLeft(32, '0'),
              'protection': 'encrypted',
            },
          ),
        }),
      ),
      throwsFormatException,
    );
  });
}
