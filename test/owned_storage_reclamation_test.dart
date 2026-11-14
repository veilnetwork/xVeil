import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_reclaim_budget.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'support/fake_multi_space.dart';

const report = ManagedReclaimReport(
  beforeBytes: 10,
  afterBytes: 5,
  contentRepacked: true,
  maintenanceRepacked: true,
);

class _ReadGate extends SyncWrappedAsyncKvLogStore {
  _ReadGate(super.inner);
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = true;
  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    if (hold &&
        namespace == Ns.settings &&
        utf8.decode(key) == 'file:fixture') {
      hold = false;
      entered.complete();
      await release.future;
    }
    return super.get(namespace, key);
  }
}

class _Controller extends AppController {
  _Controller({this.managed = true, this.phase = AppPhase.ready});
  final bool managed;
  final AppPhase phase;
  @override
  AppState build() => AppState(phase);
  @override
  bool get usesManagedStorage => managed;
}

class _Notifications extends NotificationService {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> cancelAll() async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }
}

class _Session extends MultiIdentitySession {
  _Session(this.active)
    : super(
        SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
        runtimeDirBase: '/private/tmp/xveil-owned-maintenance-unused',
        listenPortBase: 19000,
      );
  final Storage active;
  @override
  Storage? storageFor(String label) => active;
}

Future<HiddenVolumeStorage> opened(
  Future<ManagedReclaimReport> Function(bool)? reclaim, {
  AsyncKvLogStore? backing,
}) async {
  final store = backing ?? SyncWrappedAsyncKvLogStore(FakeKvLogStore());
  final storage = HiddenVolumeStorage.async(
    ({required password, required create}) async => store,
    ownedReclaimer: reclaim,
  );
  expect(
    await storage.open(password: 'synthetic', createIfMissing: true),
    isTrue,
  );
  return storage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'reclamation follows accepted file publication on the same facade',
    () async {
      final raw = FakeKvLogStore();
      final gate = _ReadGate(raw);
      var calls = 0;
      final storage = await opened((force) async {
        calls++;
        expect(force, isTrue);
        expect(
          raw.get(Ns.settings, Uint8List.fromList(utf8.encode('file:fixture'))),
          isNotNull,
        );
        return report;
      }, backing: gate);
      final write = storage.storeFile('fixture', Uint8List.fromList([1, 2, 3]));
      await gate.entered.future;
      final reclaim = storage.reclaimOwnedStorage(force: true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      gate.release.complete();
      try {
        await write;
        expect(await reclaim, same(report));
        expect(await storage.loadFile('fixture'), [1, 2, 3]);
      } finally {
        await storage.close();
      }
    },
  );

  for (final fails in [false, true]) {
    test('close joins accepted reclamation, failure=$fails', () async {
      final entered = Completer<void>(), release = Completer<void>();
      final storage = await opened((force) async {
        entered.complete();
        await release.future;
        if (fails) throw StateError('synthetic maintenance refusal');
        return report;
      });
      final reclaim = storage.reclaimOwnedStorage(force: true);
      final observed = fails ? expectLater(reclaim, throwsStateError) : reclaim;
      await entered.future;
      var closed = false;
      final closing = storage.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      await expectLater(
        storage.storeFile('late', Uint8List(1)),
        throwsStateError,
      );
      release.complete();
      await observed;
      await closing;
      expect(storage.isOpen, isFalse);
      await expectLater(storage.reclaimOwnedStorage(), throwsStateError);
    });
  }

  test(
    'unsupported legacy facade never attempts independent reclamation',
    () async {
      final storage = await opened(null);
      try {
        expect(storage.supportsOwnedReclamation, isFalse);
        await expectLater(
          storage.reclaimOwnedStorage(),
          throwsUnsupportedError,
        );
        await storage.putSetting('kept', 'unchanged');
        expect(await storage.getSetting('kept'), 'unchanged');
      } finally {
        await storage.close();
      }
    },
  );

  for (final end in ['none', 'lock', 'dispose']) {
    test('controller fences overlap and late completion after $end', () async {
      final entered = Completer<void>(), release = Completer<void>();
      var calls = 0;
      final storage = await opened((force) async {
        calls++;
        expect(force, isTrue);
        entered.complete();
        await release.future;
        return report;
      });
      final ctrl = _Controller();
      final app = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => ctrl),
          singleSpaceStorageProvider.overrideWithValue(storage),
        ],
      );
      app.read(appControllerProvider);
      final job = ctrl.reclaimOwnedStorage();
      final observed = end == 'none' ? job : expectLater(job, throwsStateError);
      await entered.future;
      await expectLater(ctrl.reclaimOwnedStorage(), throwsStateError);
      await expectLater(ctrl.beginCompactionCollection(), throwsStateError);
      var joined = false;
      final joining = ctrl.waitForCompaction().then((_) => joined = true);
      await Future<void>.delayed(Duration.zero);
      expect(joined, isFalse);
      Future<void>? locking;
      if (end == 'lock') locking = ctrl.lock();
      if (end == 'dispose') {
        app.dispose();
      }
      release.complete();
      try {
        await observed;
        await joining;
        await locking;
        expect(calls, 1);
        if (end != 'dispose') {
          expect(
            app.read(appControllerProvider).phase,
            end == 'lock' ? AppPhase.locked : AppPhase.ready,
          );
        }
      } finally {
        if (end != 'dispose') app.dispose();
        await storage.close();
      }
    });
  }

  for (final kind in ['independent', 'collection']) {
    test(
      'refuses $kind maintenance while online identity activation is pending',
      () async {
        var calls = 0;
        final storage = await opened((_) async {
          calls++;
          return report;
        });
        final ctrl = _Controller();
        final notices = _Notifications();
        final session = _Session(storage);
        final app = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => ctrl),
            singleSpaceStorageProvider.overrideWithValue(storage),
            sessionProvider.overrideWith((_) => session),
            notificationServiceProvider.overrideWithValue(notices),
          ],
        );
        app.read(appControllerProvider);
        final switching = ctrl.switchIdentity('target');
        await notices.entered.future;
        try {
          Object? refusal;
          try {
            if (kind == 'independent') {
              await ctrl.reclaimOwnedStorage();
            } else {
              await ctrl.beginCompactionCollection();
            }
          } catch (error) {
            refusal = error;
          }
          expect(refusal, isA<StateError>());
          expect(calls, 0);
          expect(ctrl.canReclaimOwnedStorage, isFalse);
          expect(app.read(appControllerProvider).phase, AppPhase.ready);
        } finally {
          notices.release.complete();
          await switching;
          app.dispose();
          await session.disposeAll();
          await storage.close();
        }
      },
    );
  }

  test(
    'a failed attempt can retry without closing or changing the facade',
    () async {
      var calls = 0;
      final storage = await opened((_) async {
        if (++calls == 1) throw StateError('synthetic refusal');
        return report;
      });
      try {
        await expectLater(storage.reclaimOwnedStorage(), throwsStateError);
        await storage.storeFile('retained', Uint8List.fromList([4, 5]));
        expect(await storage.reclaimOwnedStorage(), same(report));
        expect(await storage.loadFile('retained'), [4, 5]);
        expect(calls, 2);
      } finally {
        await storage.close();
      }
    },
  );

  test(
    'a ready legacy view cannot use the independent-maintenance path',
    () async {
      var calls = 0;
      final storage = await opened((_) async {
        calls++;
        return report;
      });
      final ctrl = _Controller(managed: false);
      final app = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => ctrl),
          singleSpaceStorageProvider.overrideWithValue(storage),
        ],
      );
      app.read(appControllerProvider);
      try {
        expect(ctrl.canReclaimOwnedStorage, isFalse);
        await expectLater(ctrl.reclaimOwnedStorage(), throwsStateError);
        expect(calls, 0);
      } finally {
        app.dispose();
        await storage.close();
      }
    },
  );

  for (final managed in [false, true]) {
    for (final phase in [AppPhase.locked, AppPhase.identitySetupRecovery]) {
      test('refuses maintenance when managed=$managed phase=$phase', () async {
        var calls = 0;
        final storage = await opened((_) async {
          calls++;
          return report;
        });
        final ctrl = _Controller(managed: managed, phase: phase);
        final app = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => ctrl),
            singleSpaceStorageProvider.overrideWithValue(storage),
          ],
        );
        app.read(appControllerProvider);
        try {
          expect(ctrl.canReclaimOwnedStorage, isFalse);
          await expectLater(ctrl.reclaimOwnedStorage(), throwsStateError);
          expect(calls, 0);
        } finally {
          app.dispose();
          await storage.close();
        }
      });
    }
  }
}
