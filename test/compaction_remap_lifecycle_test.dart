import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.ready);
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

enum _Stage { native, firstOpen, firstRosterRead, masterRosterRead }

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener, {required this.stage, super.keysOpener});
  final _Stage stage;
  final entered = Completer<void>();
  final release = Completer<void>();
  final opened = <String>[];
  String? currentPassword;
  var masterVisits = 0;
  var rosterWrites = 0;

  Future<void> park(_Stage here) async {
    if (stage != here || entered.isCompleted) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    opened.add(password);
    final result = await super.open(
      password: password,
      createIfMissing: createIfMissing,
    );
    currentPassword = password;
    if (password == 'master-fixture') masterVisits++;
    if (opened.length == 1) await park(_Stage.firstOpen);
    return result;
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    final result = await super.loadRoster();
    if (opened.length == 1) await park(_Stage.firstRosterRead);
    if (currentPassword == 'master-fixture' && masterVisits == 2) {
      await park(_Stage.masterRosterRead);
    }
    return result;
  }

  @override
  Future<void> saveRoster(List<RosterEntry> entries) {
    rosterWrites++;
    return super.saveRoster(entries);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final stage in _Stage.values) {
    for (final attemptUnlock in [false, true]) {
      test(
        'lock ends compaction storage access at ${stage.name} (unlock=$attemptUnlock)',
        () async {
          final dir = await Directory.systemTemp.createTemp(
            'xveil-remap-lifecycle-',
          );
          addTearDown(() => dir.delete(recursive: true));
          final path = '${dir.path}/fixture.hv';
          await File(path).writeAsString('owned synthetic container');
          final fake = FakeHvContainer();
          final roster = CompactionRoster();
          final oldKeys = <String, Uint8List>{};
          for (final password in ['child-fixture', 'master-fixture']) {
            final seed = fake.storage();
            await seed.open(password: password, createIfMissing: true);
            if (password == 'master-fixture') {
              await seed.saveRoster([
                RosterEntry(
                  label: 'child',
                  spaceKeys: oldKeys['child-fixture']!,
                ),
              ]);
            }
            oldKeys[password] = await seed.exportSpaceKeys();
            roster.addUnlocked(
              password,
              passwordBytes: password.codeUnits,
              spaceKeys: oldKeys[password],
            );
            await seed.close();
          }
          final storage = _Storage(
            fake.passwordOpener,
            stage: stage,
            keysOpener: fake.keysOpener,
          );
          final controller = _Controller();
          final c = ProviderContainer(
            overrides: [
              appControllerProvider.overrideWith(() => controller),
              singleSpaceStorageProvider.overrideWithValue(storage),
              notificationServiceProvider.overrideWithValue(_Notifications()),
              deniableBootProvider.overrideWithValue(
                DeniableBootConfig(
                  runtimeDir: '${dir.path}/runtime',
                  storePath: path,
                ),
              ),
              containerCompactorProvider.overrideWithValue((
                path,
                passwords, {
                dylibPath,
              }) async {
                await storage.park(_Stage.native);
                fake.rotateSalt();
              }),
            ],
          );
          addTearDown(c.dispose);
          c.read(appControllerProvider);
          final compacting = controller.compactStorageKeeping(
            roster: roster,
            reopenWith: 'master-fixture',
          );
          final refused = expectLater(compacting, throwsStateError);
          await storage.entered.future;
          await controller.lock();
          final callsAtLock = storage.opened.length;
          expect(c.read(appControllerProvider).phase, AppPhase.locked);
          expect(storage.isOpen, isFalse);
          try {
            // This must not compete with the still accepted native rewrite or its
            // remap. An ordinary failed password is sufficient to observe whether
            // the new unlock reaches the shared facade at all, without node boot.
            if (attemptUnlock) {
              await controller.unlock('missing-fixture-password');
            }
            expect(
              storage.opened.length,
              callsAtLock,
              reason: 'a new unlock entered an unfinished compaction',
            );
          } finally {
            storage.release.complete();
            await refused;
          }
          expect(
            storage.opened.length,
            callsAtLock,
            reason: 'the old remap reopened a space after lock completed',
          );
          expect(storage.rosterWrites, 0);
          expect(storage.isOpen, isFalse);
          expect(c.read(appControllerProvider).phase, AppPhase.locked);

          // Once maintenance has settled the unlock gate must release, including
          // the failure path; it is not a permanent "container busy" workaround.
          await controller.unlock('missing-fixture-password');
          expect(storage.opened.length, callsAtLock + 1);
          final reader = fake.storage();
          expect(await reader.open(password: 'master-fixture'), isTrue);
          expect((await reader.loadRoster())!.single.label, 'child');
          await reader.close();
        },
      );
    }
  }
}
