import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _CloseFailure extends HiddenVolumeStorage {
  _CloseFailure(super.opener);
  bool armed = false;
  final closing = Completer<void>();
  final release = Completer<void>();
  final opened = <String>[];
  int profileReads = 0;

  @override
  Future<bool> open({required String password, bool createIfMissing = false}) {
    opened.add(password);
    return super.open(password: password, createIfMissing: createIfMissing);
  }

  @override
  Future<UserProfile?> loadProfile() async {
    // Keep this test out of node boot. It observes the real unlock/automatic
    // recovery path up to profile classification, not network initialization.
    profileReads++;
    throw StateError('fixture profile classification stops here');
  }

  @override
  Future<void> close() async {
    if (armed) {
      armed = false;
      closing.complete();
      await release.future;
      await super.close();
      throw StateError('fixture close failure before native rewrite');
    }
    await super.close();
  }
}

class _BeforeOpenGate extends _CloseFailure {
  _BeforeOpenGate(super.opener);
  bool parkNextOpen = false;
  final opening = Completer<void>();
  final continueOpen = Completer<void>();

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    if (parkNextOpen) {
      parkNextOpen = false;
      opening.complete();
      await continueOpen.future;
    }
    return super.open(password: password, createIfMissing: createIfMissing);
  }
}

enum _Stage { closeFailure, nativeSuccess, nativeFailure }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('an old unlock cannot start auto-compaction after a lock', () async {
    final directory = await Directory.systemTemp.createTemp('xveil-auto-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/fixture.hv';
    final file = await File(path).open(mode: FileMode.write);
    await file.truncate(16 << 20);
    await file.close();
    final storage = _BeforeOpenGate(FakeHvContainer().passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.putSetting('storage.autocompact.v1', '1');
    await storage.close();
    storage.opened.clear();
    storage.parkNextOpen = true;
    var rewrites = 0;
    final controller = _Controller();
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => controller),
        singleSpaceStorageProvider.overrideWithValue(storage),
        notificationServiceProvider.overrideWithValue(_Notifications()),
        containerCompactorProvider.overrideWithValue((
          path,
          passwords, {
          dylibPath,
        }) async {
          rewrites++;
        }),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${directory.path}/runtime',
            storePath: path,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(appControllerProvider);
    final unlocking = controller.unlock('fixture');
    await storage.opening.future;
    await controller.lock();
    storage.continueOpen.complete();
    await unlocking;
    expect(rewrites, 0);
    expect(storage.isOpen, isFalse);
    expect(storage.profileReads, 0);
    expect(container.read(appControllerProvider).phase, AppPhase.locked);
    await storage.close();
  });
  for (final stage in _Stage.values) {
    for (final lockDuringClose in [false, true]) {
      test('auto-compaction $stage respects lock=$lockDuringClose', () async {
        final directory = await Directory.systemTemp.createTemp('xveil-auto-');
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/fixture.hv';
        final file = await File(path).open(mode: FileMode.write);
        await file.truncate(16 << 20);
        await file.close();
        // Only a size witness. This branch must fail before native rewrite.
        final storage = _CloseFailure(FakeHvContainer().passwordOpener);
        await storage.open(password: 'fixture', createIfMissing: true);
        await storage.putSetting('storage.autocompact.v1', '1');
        await storage.close();
        storage.opened.clear();
        storage.armed = stage == _Stage.closeFailure;
        final backendEntered = Completer<void>();
        final backendPublish = Completer<void>();
        var backendCalls = 0;
        final controller = _Controller();
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            singleSpaceStorageProvider.overrideWithValue(storage),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            containerCompactorProvider.overrideWithValue((
              path,
              passwords, {
              dylibPath,
            }) async {
              backendCalls++;
              backendEntered.complete();
              await backendPublish.future;
              if (stage == _Stage.nativeFailure) {
                throw StateError('fixture backend refusal');
              }
            }),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '${directory.path}/runtime',
                storePath: path,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(appControllerProvider);
        final unlocking = controller.unlock('fixture');
        await (stage == _Stage.closeFailure
            ? storage.closing.future
            : backendEntered.future);
        if (lockDuringClose) await controller.lock();
        if (stage == _Stage.closeFailure) {
          storage.release.complete();
        } else {
          backendPublish.complete();
        }
        await unlocking;
        expect(
          storage.opened,
          lockDuringClose ? ['fixture'] : ['fixture', 'fixture'],
          reason: 'a stale recovery must never open the locked container again',
        );
        expect(storage.profileReads, lockDuringClose ? 0 : 1);
        expect(backendCalls, stage == _Stage.closeFailure ? 0 : 1);
        expect(storage.isOpen, isFalse);
        expect(container.read(appControllerProvider).phase, AppPhase.locked);
        await storage.close();
      });
    }
  }
}
