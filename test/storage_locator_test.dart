import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  final encrypted = ManagedStorageLocator(
    id: ManagedIdentityId('a' * 32),
    protection: StorageProtection.encrypted,
  );
  final plain = ManagedStorageLocator(
    id: ManagedIdentityId('a' * 32),
    protection: StorageProtection.unencrypted,
  );
  test(
    'the locator preserves mode and has no filesystem path or credential',
    () {
      for (final location in [const LegacyStorageLocator(), encrypted, plain]) {
        expect(
          IdentityStorageLocator.decode(
            jsonDecode(jsonEncode(location.encode())),
          ),
          location,
        );
      }
      expect(encrypted, isNot(plain));
      expect(encrypted.encode().keys.toSet(), {
        'v',
        'kind',
        'id',
        'protection',
      });
      final entry = ManagedIdentityEntry.fromLocator(encrypted);
      expect(entry.locator, encrypted);
    },
  );

  test('invalid, extra, hidden and path-based locators never mean legacy', () {
    for (final raw in [
      null,
      '',
      [],
      {},
      {'v': 1.0, 'kind': 'legacy'},
      {'v': 2, 'kind': 'legacy'},
      {'v': 1, 'kind': 'legacy', 'id': 'a' * 32},
      {'v': 1, 'kind': 'legacy', 'password': 'synthetic'},
      {'v': 1, 'kind': 'unknown'},
      {...encrypted.encode(), 'path': '/synthetic/path'},
      {...encrypted.encode(), 'id': '../synthetic'},
      {...encrypted.encode(), 'id': 'A' * 32},
      {...encrypted.encode(), 'id': 'a' * 33},
      {...encrypted.encode(), 'protection': 'hidden'},
      {...encrypted.encode(), 'protection': 'plain'},
    ]) {
      expect(
        () => IdentityStorageLocator.decode(raw),
        throwsA(isA<InvalidStorageLocator>()),
      );
    }
    expect(
      () => ManagedStorageLocator(
        id: encrypted.id,
        protection: StorageProtection.hidden,
      ),
      throwsA(isA<InvalidStorageLocator>()),
    );
    expect(const InvalidStorageLocator().toString(), 'InvalidStorageLocator');
  });

  test('roster edits and key snapshots preserve the immutable locator', () {
    final original = RosterEntry(
      label: 'fixture',
      spaceKeys: Uint8List(64),
      storageLocator: encrypted,
    );
    final copy = original.copyWith(
      label: 'renamed',
      anonymous: true,
      spaceKeys: Uint8List(64)..[0] = 1,
    );
    expect(copy.storageLocator, encrypted);
    expect(original.storageLocator, encrypted);
    expect(copy.spaceKeys[0], 1);
    expect(copy.anonymous, isTrue);
  });

  for (final count in [1, 24]) {
    test(
      'managed locator survives ${count == 1 ? 'inline' : 'file-backed'} roster persistence',
      () async {
        final raw = FakeKvLogStore();
        final storage = HiddenVolumeStorage.fromAsyncStore(
          SyncWrappedAsyncKvLogStore(raw),
        );
        addTearDown(storage.close);
        final rows = [
          for (var i = 0; i < count; i++)
            RosterEntry(
              label: 'synthetic row $i',
              spaceKeys: Uint8List(64)..[0] = i,
              storageLocator: i.isEven ? encrypted : plain,
            ),
        ];
        await storage.saveRoster(rows);
        final read = await storage.loadRoster();
        expect(read, hasLength(count));
        for (var i = 0; i < count; i++) {
          expect(read![i].storageLocator, rows[i].storageLocator);
          expect(read[i].spaceKeys, rows[i].spaceKeys);
        }
        expect(await storage.hasFile('master:roster.v2'), count > 1);
      },
    );
  }

  test(
    'historical rosters keep their legacy location and exact stored bytes',
    () async {
      final raw = FakeKvLogStore();
      final storage = HiddenVolumeStorage.fromAsyncStore(
        SyncWrappedAsyncKvLogStore(raw),
      );
      addTearDown(storage.close);
      final encoded = bytes(
        jsonEncode([
          {'l': 'fixture', 'k': base64Encode(Uint8List(64))},
        ]),
      );
      raw.commit([PutOp(Ns.settings, bytes('master:roster'), encoded)]);
      final rows = await storage.loadRoster();
      expect(rows!.single.storageLocator, const LegacyStorageLocator());
      await storage.saveRoster(rows);
      expect(raw.get(Ns.settings, bytes('master:roster')), encoded);
    },
  );

  test(
    'a corrupt explicit location refuses load and cannot erase the roster',
    () async {
      final raw = FakeKvLogStore();
      final storage = HiddenVolumeStorage.fromAsyncStore(
        SyncWrappedAsyncKvLogStore(raw),
      );
      addTearDown(storage.close);
      for (final location in [
        null,
        {},
        {...encrypted.encode(), 'protection': 'hidden'},
      ]) {
        final encoded = bytes(
          jsonEncode([
            {'l': 'fixture', 'k': base64Encode(Uint8List(64)), 's': location},
          ]),
        );
        raw.commit([PutOp(Ns.settings, bytes('master:roster'), encoded)]);
        await expectLater(
          storage.loadRoster(),
          throwsA(isA<InvalidStorageLocator>()),
        );
        await expectLater(
          storage.saveRoster([]),
          throwsA(isA<InvalidStorageLocator>()),
        );
        expect(raw.get(Ns.settings, bytes('master:roster')), encoded);
      }
    },
  );
}
