import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';

void main() {
  final library = Platform.environment['XVEIL_HV_DYLIB'];
  for (final reverse in [false, true]) {
    test(
      'real two-space compaction preserves both passwords (reverse=$reverse)',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final dir = await Directory.systemTemp.createTemp('xv-compact-two-');
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/fixture.hv';
        final passwords = [' hidden-fixture ', 'открытое-пространство'];
        final contents = Uint8List.fromList(
          List.generate(70000, (i) => i % 251),
        );
        final oldKeys = <Uint8List>[];
        final roster = CompactionRoster();
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: Uint8List.fromList(utf8.encode(passwords.first)),
            argon: hv.ArgonPreset.min,
          ),
        ).close();
        for (var i = 0; i < passwords.length; i++) {
          final store = HiddenVolumeStorage.async(workerSpaceOpener(path));
          try {
            expect(
              await store.open(password: passwords[i], createIfMissing: true),
              isTrue,
            );
            await store.saveProfile(UserProfile(displayName: 'fixture-$i'));
            await store.storeFile('fixture-body', contents);
            for (var n = 0; n < 16; n++) {
              await store.putSetting('fixture-version', '$n');
            }
            oldKeys.add(await store.exportSpaceKeys());
          } finally {
            await store.close();
          }
        }
        for (final i in reverse ? [1, 0] : [0, 1]) {
          // Use the dialog's exact repeated-password collection path.
          roster.addUnlocked(
            'fixture-$i',
            passwordBytes: utf8.encode(passwords[i]),
            spaceKeys: oldKeys[i],
          );
          roster.addUnlocked(
            'repeat-$i',
            passwordBytes: utf8.encode(passwords[i]),
            spaceKeys: oldKeys[i],
          );
        }
        expect(roster.passwords(), hasLength(2));
        await hv.compactKnownAsync(
          path,
          roster.passwords().map(Uint8List.fromList).toList(),
          dylibPath: library,
        );
        for (var i = 0; i < passwords.length; i++) {
          // A fresh worker and facade per password, as after a full restart.
          final reopened = HiddenVolumeStorage.async(workerSpaceOpener(path));
          try {
            expect(await reopened.open(password: passwords[i]), isTrue);
            expect((await reopened.loadProfile())?.displayName, 'fixture-$i');
            expect(await reopened.loadFile('fixture-body'), contents);
            expect(await reopened.getSetting('fixture-version'), '15');
          } finally {
            await reopened.close();
          }
        }
      },
      skip: library == null
          ? 'set XVEIL_HV_DYLIB to a qualified library'
          : false,
    );
  }
  test(
    'refused rewrite preserves the source and reused passwords add no space',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final dir = await Directory.systemTemp.createTemp('xv-compact-refusal-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/fixture.hv';
      final password = Uint8List.fromList(utf8.encode('fixture-password'));
      HvKvLogStore(
        hv.HvSpace.create(
          path: path,
          password: password,
          argon: hv.ArgonPreset.min,
        ),
      ).close();
      final store = HiddenVolumeStorage.async(workerSpaceOpener(path));
      try {
        expect(await store.open(password: 'fixture-password'), isTrue);
        await store.saveProfile(const UserProfile(displayName: 'original'));
      } finally {
        await store.close();
      }
      expect(
        () => hv.HvSpace.addSpace(path: path, password: password),
        throwsA(
          isA<hv.HvException>().having(
            (e) => e.kind,
            'kind',
            'SpaceAlreadyExists',
          ),
        ),
      );
      final original = await File(path).readAsBytes();
      await expectLater(
        hv.compactKnownAsync(path, [
          password,
          Uint8List.fromList(utf8.encode('incorrect-fixture')),
        ], dylibPath: library),
        throwsA(isA<hv.HvException>()),
      );
      expect(await File(path).readAsBytes(), original);
      final reopened = HiddenVolumeStorage.async(workerSpaceOpener(path));
      try {
        expect(await reopened.open(password: 'fixture-password'), isTrue);
        expect((await reopened.loadProfile())?.displayName, 'original');
      } finally {
        await reopened.close();
      }
    },
    skip: library == null ? 'set XVEIL_HV_DYLIB to a qualified library' : false,
  );
}
