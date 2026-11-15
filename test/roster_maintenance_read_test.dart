import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.ready);
}

void main() {
  for (final repair in [false, true]) {
    test(
      'compaction refuses unreadable master before publication (repair=$repair)',
      () async {
        final fake = FakeHvContainer();
        final seed = fake.storage();
        final credentials = <({List<int> password, List<int> oldSpaceKeys})>[];
        for (final password in ['child', 'master']) {
          expect(
            await seed.open(password: password, createIfMissing: true),
            isTrue,
          );
          if (password == 'master') {
            await seed.saveRoster([
              RosterEntry(
                label: 'child',
                spaceKeys: Uint8List.fromList(credentials.first.oldSpaceKeys),
              ),
            ]);
          }
          credentials.add((
            password: _bytes(password),
            oldSpaceKeys: await seed.exportSpaceKeys(),
          ));
          await seed.close();
        }
        final rosterKey = _bytes('master:roster');
        fake.rawStoreFor('master')!.commit([
          PutOp(Ns.settings, rosterKey, _bytes('unreadable roster')),
        ]);
        if (repair) fake.rotateSalt();
        final storage = fake.storage();
        final controller = _Controller();
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            storageProvider.overrideWithValue(storage),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(storage.close);
        container.read(appControllerProvider);
        if (repair) {
          expect(
            await controller.remapRostersAfterCompaction(credentials),
            isNotEmpty,
          );
        } else {
          final result = await controller.probeCompactionIdentity('master');
          expect(result.opened, isFalse);
          expect(result.spaceKeys, isNull);
        }
        expect(
          fake.rawStoreFor('master')!.get(Ns.settings, rosterKey),
          _bytes('unreadable roster'),
        );
      },
    );
  }

  for (final malformed in [
    'not json',
    '{}',
    jsonEncode([
      {'l': 'fixture', 'k': base64.encode(Uint8List(63))},
    ]),
    jsonEncode([
      {'l': 'fixture', 'k': base64.encode(Uint8List(64)), 'unknown': true},
    ]),
    jsonEncode([
      {'l': 'fixture', 'k': base64.encode(Uint8List(64)), 'a': '1'},
    ]),
  ]) {
    test(
      'maintenance refuses an unreadable or unsupported roster row ${malformed.length}',
      () async {
        final fake = FakeHvContainer();
        final storage = fake.storage();
        addTearDown(storage.close);
        expect(
          await storage.open(password: 'fixture', createIfMissing: true),
          isTrue,
        );
        final raw = fake.rawStoreFor('fixture')!;
        final key = _bytes('master:roster');
        raw.commit([PutOp(Ns.settings, key, _bytes(malformed))]);
        final sequence = raw.commitSeq();
        await expectLater(storage.loadRosterForMaintenance(), throwsStateError);
        expect(raw.commitSeq(), sequence);
        expect(raw.get(Ns.settings, key), _bytes(malformed));
      },
    );
  }

  test('maintenance distinguishes absent and empty valid rosters', () async {
    final fake = FakeHvContainer();
    final storage = fake.storage();
    addTearDown(storage.close);
    expect(
      await storage.open(password: 'fixture', createIfMissing: true),
      isTrue,
    );
    expect(await storage.loadRosterForMaintenance(), isNull);
    await storage.saveRoster([]);
    expect(await storage.loadRosterForMaintenance(), isEmpty);
  });

  test('unreadable declared roster file is never treated as absent', () async {
    final fake = FakeHvContainer();
    final storage = fake.storage();
    addTearDown(storage.close);
    expect(
      await storage.open(password: 'fixture', createIfMissing: true),
      isTrue,
    );
    await storage.saveRoster([
      for (var i = 0; i < 20; i++)
        RosterEntry(
          label: 'fixture-$i',
          spaceKeys: Uint8List(64)..[0] = i,
          anonymous: true,
        ),
    ]);
    expect(await storage.loadRosterForMaintenance(), hasLength(20));
    final raw = fake.rawStoreFor('fixture')!;
    final key = _bytes('file:master:roster.v2');
    expect(raw.get(Ns.settings, key), isNotNull);
    raw.commit([PutOp(Ns.settings, key, _bytes('unreadable metadata'))]);
    final sequence = raw.commitSeq();
    expect(
      await storage.loadRoster(),
      isNull,
      reason: 'historical read is ambiguous for this metadata',
    );
    await expectLater(storage.loadRosterForMaintenance(), throwsStateError);
    expect(raw.commitSeq(), sequence);
    expect(raw.get(Ns.settings, key), _bytes('unreadable metadata'));
  });
}
