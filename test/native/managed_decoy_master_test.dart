@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart'
    show kSovereignBundleSetting;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_setup.dart';
import 'package:xveil/domain/pending_identity_erase.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';
import 'package:xveil/state/voice_record_controller.dart';

class _Recorder implements VoiceRecorder {
  bool stopped = false, disposed = false;
  @override
  bool start() => true;
  @override
  double get level => 0;
  @override
  int get elapsedMs => 0;
  @override
  VoiceClip? stop({int waveformBars = 48}) {
    stopped = true;
    return null;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class _Node implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

class _Transport implements VeilTransport {
  final _inbound = StreamController<InboundMessage>.broadcast();
  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

enum _Point { opened, marked, beforeSave, saved, closed, revoke }

class _Fault {
  _Fault(this.point, {this.fail = false});
  final _Point point;
  final bool fail;
  bool hit = false;
  final entered = Completer<void>(), release = Completer<void>();
  final exported = <Uint8List>[];
  Future<void> at(_Point point) async {
    if (this.point != point || hit) return;
    hit = true;
    entered.complete();
    if (fail) throw StateError('synthetic duress refusal');
    await release.future;
  }
}

class _ObservedStorage extends HiddenVolumeStorage {
  _ObservedStorage(String path, this.fault)
    : super(
        hvSpaceOpener(
          path,
          argon: hv.ArgonPreset.min,
          paddingPreset: hv.PaddingPreset.none,
        ),
        keysOpener: hvKeysSpaceOpener(path),
      );
  final _Fault? Function() fault;
  bool target = false;
  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    target = password == 'synthetic duress';
    final result = await super.open(
      password: password,
      createIfMissing: createIfMissing,
    );
    if (target && result) await fault()?.at(_Point.opened);
    return result;
  }

  @override
  Future<bool> openWithKeys(Uint8List keys) {
    target = false;
    return super.openWithKeys(keys);
  }

  @override
  Future<Uint8List> exportSpaceKeys() async {
    final keys = await super.exportSpaceKeys();
    if (target) fault()?.exported.add(keys);
    return keys;
  }

  @override
  Future<void> putSetting(String key, String value) async {
    if (!target && key == 'storage.autocompact.v1' && value == '0') {
      await fault()?.at(_Point.revoke);
    }
    await super.putSetting(key, value);
    if (target && key == kPendingMasterSetupSetting && value == '1') {
      await fault()?.at(_Point.marked);
    }
  }

  @override
  Future<void> saveRoster(List<RosterEntry> roster) async {
    if (target) await fault()?.at(_Point.beforeSave);
    await super.saveRoster(roster);
    if (target) await fault()?.at(_Point.saved);
  }

  @override
  Future<void> close() async {
    await super.close();
    if (target) await fault()?.at(_Point.closed);
    target = false;
  }
}

class _Stand {
  _Stand(this.mode, {this.hosted = false, this.visibleOnly = false});
  final StorageProtection mode;
  final bool hosted, visibleOnly;
  _Fault? fault;
  late final Directory temporary;
  late final String profile, legacyPath;
  final routers = <ProfileStorageRouter>[];
  final apps = <ProviderContainer>[];
  final keys = <Uint8List>[];
  final rows = <RosterEntry>[];
  final recorders = <_Recorder>[];
  late ProfileStorageRouter live;
  late ProviderContainer app;
  late IdentityStorageLocator master;
  late Uint8List masterKeys;
  static const labels = [
    'safe-hidden',
    'safe-encrypted',
    'safe-plain',
    'sensitive-hidden',
  ];
  String get password =>
      mode == StorageProtection.unencrypted ? '' : 'synthetic master';
  AppController get controller => app.read(appControllerProvider.notifier);
  Future<ProfileStorageRouter> open() async {
    final router = await ProfileStorageRouter.open(
      profileDirectory: profile,
      legacyFactory: () => _ObservedStorage(legacyPath, () => fault),
    );
    routers.add(router);
    return router;
  }

  Future<ProviderContainer> bind(ProfileStorageRouter router) async {
    final container = ProviderContainer(
      overrides: [
        profileStorageRouterProvider.overrideWithValue(router),
        singleSpaceStorageProvider.overrideWith((ref) {
          ref.watch(storageRouteRevisionProvider);
          return router.storage;
        }),
        nodeControllerProvider.overrideWithValue(_Node()),
        micPermissionProvider.overrideWithValue(() async => true),
        voiceRecorderFactoryProvider.overrideWithValue(() {
          final recorder = _Recorder();
          recorders.add(recorder);
          return recorder;
        }),
        if (hosted)
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${temporary.path}/runtime',
              storePath: legacyPath,
            ),
          ),
        if (hosted)
          sessionBuilderProvider.overrideWithValue(
            ({
              required storePath,
              required runtimeDir,
              required listenPort,
              required peersFor,
              obfs4Psk,
              required udpReflectors,
              required lazyMining,
              required proxy,
              required paddingPreset,
            }) => MultiIdentitySession(
              WorkerMultiSpaceBacking(
                storePath,
                paddingPreset: hv.PaddingPreset.none,
              ),
              managedProfileDirectory: profile,
              runtimeDirBase: runtimeDir,
              listenPortBase: listenPort,
              boot: (_, _) async {
                final transport = _Transport();
                return IdentityNode(
                  transport: transport,
                  dispose: transport.dispose,
                );
              },
            ),
          ),
      ],
    );
    apps.add(container);
    container.read(appControllerProvider.notifier).debugDeniableStackStarter =
        (_) async => throw StateError('synthetic stand disables network');
    await container.read(prefsProvider.future);
    await Future<void>.delayed(Duration.zero);
    return container;
  }

  Future<void> initialize() async {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    SharedPreferences.setMockInitialValues({});
    temporary = Directory.systemTemp.createTempSync('xveil-managed-decoy-');
    profile = '${temporary.path}/profile';
    legacyPath = '$profile/legacy.hv';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    live = await open();
    for (var i = 0; i < labels.length; i++) {
      final protection = [
        StorageProtection.hidden,
        StorageProtection.encrypted,
        StorageProtection.unencrypted,
        StorageProtection.hidden,
      ][i];
      if (visibleOnly && protection == StorageProtection.hidden) continue;
      await live.create(protection);
      expect(
        await live.storage.open(
          password: protection == StorageProtection.unencrypted
              ? ''
              : 'synthetic child $i',
          createIfMissing: true,
        ),
        isTrue,
      );
      await live.storage.saveProfile(UserProfile(displayName: labels[i]));
      await live.storage.putSetting('fixture-owner', labels[i]);
      if (protection == StorageProtection.hidden) {
        await live.storage.putSetting('storage.autocompact.v1', '1');
      }
      final key = await live.storage.exportSpaceKeys();
      keys.add(key);
      rows.add(
        RosterEntry(
          label: labels[i],
          spaceKeys: key,
          storageLocator: live.location,
          anonymous: i == 0,
        ),
      );
      await live.storage.close();
    }
    await live.create(mode);
    master = live.location;
    expect(
      await live.storage.open(password: password, createIfMissing: true),
      isTrue,
    );
    await live.storage.saveRoster(rows);
    await live.storage.putSetting('fixture-master', 'preserve');
    masterKeys = await live.storage.exportSpaceKeys();
    keys.add(masterKeys);
    await live.rememberAccess();
    await live.storage.close();
    app = await bind(live);
    if (mode == StorageProtection.hidden) {
      expect(await controller.selectStorageIdentity(master), isTrue);
    }
    await controller.unlock(password);
    expect(
      app.read(appControllerProvider).phase,
      hosted ? AppPhase.ready : AppPhase.pickingIdentity,
    );
    await controller.pickIdentity(rows.last.label);
    expect(app.read(appControllerProvider).phase, AppPhase.ready);
  }

  Future<void> release(ProviderContainer container) async {
    await container.read(appControllerProvider.notifier).lock();
    container.dispose();
    apps.remove(container);
  }

  Future<void> close() async {
    final active = fault;
    if (active != null && !active.release.isCompleted) {
      active.release.complete();
    }
    for (final container in apps.toList()) {
      await release(container);
    }
    for (final router in routers) {
      await router.close();
    }
    for (final key in keys) {
      key.fillRange(0, key.length, 0);
    }
    temporary.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (mode, hosted) in [
    (StorageProtection.hidden, false),
    (StorageProtection.encrypted, false),
    (StorageProtection.unencrypted, false),
    (StorageProtection.encrypted, true),
    (StorageProtection.hidden, true),
    (StorageProtection.unencrypted, true),
  ]) {
    test(
      'mixed decoy preserves root and restores hosting; ${mode.name}/$hosted',
      () async {
        final stand = _Stand(mode, hosted: hosted);
        try {
          await stand.initialize();
          final controller = stand.controller;
          final catalog = stand.live.catalog.encode();
          final originalRootKeys = controller.debugMasterKeys!;
          await stand.app.read(voiceRecordControllerProvider.notifier).start();
          expect(
            stand.app.read(voiceRecordControllerProvider).isRecording,
            isTrue,
          );
          expect(
            await controller.createDecoyMaster(
              duressPassword: 'synthetic duress',
              includeLabels: _Stand.labels.take(3).toList(),
            ),
            isTrue,
          );
          expect(stand.app.read(appControllerProvider).phase, AppPhase.ready);
          expect(controller.activeIdentity, _Stand.labels.last);
          expect(stand.app.read(sessionProvider) != null, hosted);
          expect(
            stand.app.read(voiceRecordControllerProvider).isRecording,
            isFalse,
          );
          expect(stand.recorders.last.stopped, isTrue);
          expect(stand.recorders.last.disposed, isTrue);
          expect(stand.live.access, stand.master);
          expect(stand.live.catalog.encode(), catalog);
          expect(controller.debugMasterKeys, stand.masterKeys);
          expect(
            stand.app
                .read(screenLockProvider.notifier)
                .tryUnlock(stand.password),
            isTrue,
          );
          expect(
            await stand.app.read(storageProvider).getSetting('fixture-owner'),
            _Stand.labels.last,
          );
          await stand.release(stand.app);
          await stand.live.close();
          expect(originalRootKeys, everyElement(0));
          // A new process-like router/app has no remembered hidden target.
          stand.live = await stand.open();
          // Fresh actor reads the durable catalog, not the old router cache.
          expect(stand.live.catalog.encode(), catalog);
          stand.app = await stand.bind(stand.live);
          final cold = stand.controller;
          expect(
            await cold.selectStorageIdentity(const LegacyStorageLocator()),
            isTrue,
          );
          await cold.unlock('synthetic duress');
          expect(
            stand.app.read(appControllerProvider).phase,
            hosted ? AppPhase.ready : AppPhase.pickingIdentity,
          );
          expect(
            stand.app.read(appControllerProvider).identities,
            _Stand.labels.take(3).toList(),
          );
          expect(cold.debugRoster!.map((e) => e.label), _Stand.labels.take(3));
          for (final row in stand.rows.take(3)) {
            final actual = cold.debugRoster!.singleWhere(
              (e) => e.label == row.label,
            );
            expect(actual.storageLocator, row.storageLocator);
            expect(actual.anonymous, row.anonymous);
            expect(actual.spaceKeys, row.spaceKeys);
            await cold.pickIdentity(row.label);
            expect(stand.app.read(appControllerProvider).phase, AppPhase.ready);
            expect(
              await stand.app.read(storageProvider).getSetting('fixture-owner'),
              row.label,
            );
            expect(
              stand.app
                  .read(screenLockProvider.notifier)
                  .tryUnlock('synthetic duress'),
              isTrue,
            );
          }
          await cold.lock();
          expect(await cold.selectStorageIdentity(stand.master), isTrue);
          await cold.unlock(stand.password);
          expect(cold.debugRoster!.map((e) => e.label), _Stand.labels);
          for (var i = 0; i < stand.rows.length; i++) {
            expect(cold.debugRoster![i].spaceKeys, stand.rows[i].spaceKeys);
          }
        } finally {
          await stand.close();
        }
      },
    );
  }
  test('duress selection is snapshotted before the first await', () async {
    final stand = _Stand(StorageProtection.encrypted);
    try {
      await stand.initialize();
      final selected = [_Stand.labels.first];
      final pending = stand.controller.createDecoyMaster(
        duressPassword: 'synthetic duress',
        includeLabels: selected,
      );
      selected[0] = _Stand.labels.last;
      expect(await pending, isTrue);
      await stand.controller.lock();
      expect(
        await stand.controller.selectStorageIdentity(
          const LegacyStorageLocator(),
        ),
        isTrue,
      );
      await stand.controller.unlock('synthetic duress');
      expect(stand.app.read(appControllerProvider).identities, [
        _Stand.labels.first,
      ]);
    } finally {
      await stand.close();
    }
  });

  test('managed-only source can create its first hidden decoy', () async {
    final stand = _Stand(StorageProtection.encrypted, visibleOnly: true);
    try {
      await stand.initialize();
      expect(File(stand.legacyPath).existsSync(), isFalse);
      final catalog = stand.live.catalog.encode();
      expect(
        await stand.controller.createDecoyMaster(
          duressPassword: 'synthetic duress',
          includeLabels: stand.rows.map((e) => e.label).toList(),
        ),
        isTrue,
      );
      expect(File(stand.legacyPath).existsSync(), isTrue);
      expect(stand.live.catalog.encode(), catalog);
      await stand.controller.lock();
      expect(
        await stand.controller.selectStorageIdentity(
          const LegacyStorageLocator(),
        ),
        isTrue,
      );
      await stand.controller.unlock('synthetic duress');
      expect(
        stand.controller.debugRoster!.map((e) => e.label),
        stand.rows.map((e) => e.label),
      );
    } finally {
      await stand.close();
    }
  });

  for (final conflict in [
    'master',
    'hidden-child',
    'encrypted-child',
    'unknown-selection',
  ]) {
    test(
      'duress refuses $conflict and preserves all known identities',
      () async {
        final stand = _Stand(StorageProtection.encrypted);
        try {
          await stand.initialize();
          final catalog = stand.live.catalog.encode();
          final password = switch (conflict) {
            'master' => stand.password,
            'hidden-child' => 'synthetic child 0',
            'encrypted-child' => 'synthetic child 1',
            _ => 'synthetic duress',
          };
          expect(
            await stand.controller.createDecoyMaster(
              duressPassword: password,
              includeLabels: conflict == 'unknown-selection'
                  ? ['not-in-roster']
                  : [_Stand.labels.first],
            ),
            isFalse,
          );
          expect(stand.live.catalog.encode(), catalog);
          expect(stand.live.access, stand.master);
          expect(stand.app.read(appControllerProvider).phase, AppPhase.ready);
          expect(stand.controller.activeIdentity, _Stand.labels.last);
          await stand.controller.lock();
          expect(
            await stand.controller.selectStorageIdentity(stand.master),
            isTrue,
          );
          await stand.controller.unlock(stand.password);
          expect(
            stand.controller.debugRoster!.map((e) => e.label),
            _Stand.labels,
          );
          expect(
            stand.controller.debugRoster!.map((e) => e.storageLocator),
            stand.rows.map((e) => e.storageLocator),
          );
        } finally {
          await stand.close();
        }
      },
    );
  }

  for (final content in [
    'profile',
    'roster',
    'pending-master',
    'pending-erase',
    'credential',
  ]) {
    test('existing hidden $content is not overwritten', () async {
      final stand = _Stand(StorageProtection.encrypted);
      try {
        await stand.initialize();
        await stand.controller.lock();
        await stand.live.select(const LegacyStorageLocator(), access: false);
        final seed = stand.live.storage;
        expect(
          await seed.open(password: 'synthetic duress', createIfMissing: true),
          isTrue,
        );
        switch (content) {
          case 'profile':
            await seed.saveProfile(
              const UserProfile(displayName: 'unrelated fixture'),
            );
          case 'roster':
            await seed.saveRoster([stand.rows.last]);
          case 'pending-master':
            await seed.putSetting(kPendingMasterSetupSetting, '1');
          case 'pending-erase':
            await seed.putSetting(kPendingIdentityErase, 'fixture-intent');
          case 'credential':
            await seed.putSetting(
              kSovereignBundleSetting,
              base64Encode([1, 2, 3]),
            );
        }
        await seed.putSetting('fixture-preserve', content);
        await seed.close();
        expect(
          await stand.controller.selectStorageIdentity(stand.master),
          isTrue,
        );
        await stand.controller.unlock(stand.password);
        await stand.controller.pickIdentity(_Stand.labels.last);
        expect(
          await stand.controller.createDecoyMaster(
            duressPassword: 'synthetic duress',
            includeLabels: [_Stand.labels.first],
          ),
          isFalse,
        );
        expect(stand.app.read(appControllerProvider).phase, AppPhase.ready);
        await stand.controller.lock();
        await stand.live.select(const LegacyStorageLocator(), access: false);
        expect(
          await stand.live.storage.open(password: 'synthetic duress'),
          isTrue,
        );
        expect(
          await stand.live.storage.getSetting('fixture-preserve'),
          content,
        );
        if (content == 'roster') {
          expect(
            (await stand.live.storage.loadRoster())!.single.label,
            _Stand.labels.last,
          );
        }
        if (content == 'pending-master') {
          expect(
            await stand.live.storage.getSetting(kPendingMasterSetupSetting),
            '1',
          );
        }
        if (content == 'pending-erase') {
          expect(
            await stand.live.storage.getSetting(kPendingIdentityErase),
            'fixture-intent',
          );
        }
        await stand.live.storage.close();
      } finally {
        await stand.close();
      }
    });
  }

  for (final point in [_Point.beforeSave, _Point.closed, _Point.revoke]) {
    test(
      'refusal at $point is not success and restores original session',
      () async {
        final stand = _Stand(StorageProtection.encrypted);
        try {
          await stand.initialize();
          if (point == _Point.revoke) {
            await stand.app
                .read(storageProvider)
                .putSetting('storage.autocompact.v1', '1');
          }
          stand.fault = _Fault(point, fail: true);
          expect(
            await stand.controller.createDecoyMaster(
              duressPassword: 'synthetic duress',
              includeLabels: [_Stand.labels.first],
            ),
            isFalse,
          );
          expect(stand.fault!.hit, isTrue);
          expect(stand.app.read(appControllerProvider).phase, AppPhase.ready);
          expect(stand.controller.activeIdentity, _Stand.labels.last);
          expect(stand.live.access, stand.master);
          if (point == _Point.beforeSave) {
            await stand.controller.lock();
            expect(
              await stand.controller.selectStorageIdentity(
                const LegacyStorageLocator(),
              ),
              isTrue,
            );
            await stand.controller.unlock('synthetic duress');
            expect(
              stand.app.read(appControllerProvider).phase,
              AppPhase.identitySetupRecovery,
            );
            expect(stand.controller.canResumeIdentitySetup, isFalse);
            expect(stand.app.read(sessionProvider), isNull);
          }
        } finally {
          await stand.close();
        }
      },
    );
  }

  for (final point in [
    _Point.opened,
    _Point.marked,
    _Point.saved,
    _Point.closed,
  ]) {
    test(
      'lock after accepted $point never publishes a late decoy session',
      () async {
        final stand = _Stand(StorageProtection.encrypted);
        Future<bool>? pending;
        try {
          await stand.initialize();
          stand.fault = _Fault(point);
          final fault = stand.fault!;
          final rootKeys = stand.controller.debugMasterKeys!;
          pending = stand.controller.createDecoyMaster(
            duressPassword: 'synthetic duress',
            includeLabels: [_Stand.labels.first],
          );
          await Future.any<void>([
            fault.entered.future,
            pending.then(
              (_) => throw StateError('operation ended before native gate'),
            ),
          ]);
          final childKeys = stand.controller.debugRoster!
              .map((e) => e.spaceKeys)
              .toList();
          expect(childKeys, hasLength(4));
          expect(childKeys.every((key) => key.any((b) => b != 0)), isTrue);
          expect(
            fault.exported,
            point == _Point.opened ? isEmpty : hasLength(1),
          );
          expect(
            await stand.controller.createDecoyMaster(
              duressPassword: 'other fixture',
              includeLabels: [_Stand.labels.last],
            ),
            isFalse,
          );
          await stand.controller.lock();
          expect(stand.app.read(appControllerProvider).phase, AppPhase.locked);
          fault.release.complete();
          expect(await pending, isFalse);
          expect(stand.app.read(appControllerProvider).phase, AppPhase.locked);
          expect(stand.controller.debugMasterKeys, isNull);
          expect(stand.controller.debugRoster, isNull);
          expect(rootKeys, everyElement(0));
          expect(childKeys, everyElement(everyElement(0)));
          expect(fault.exported, everyElement(everyElement(0)));
          expect(stand.app.read(sessionProvider), isNull);
          expect(
            await stand.controller.selectStorageIdentity(stand.master),
            isTrue,
          );
          await stand.controller.unlock(stand.password);
          expect(
            stand.controller.debugRoster!.map((e) => e.label),
            _Stand.labels,
          );
        } finally {
          final fault = stand.fault;
          if (fault != null && !fault.release.isCompleted) {
            fault.release.complete();
          }
          await pending;
          await stand.close();
        }
      },
    );
  }
  test('changed durable parent cannot publish a stale decoy roster', () async {
    final stand = _Stand(StorageProtection.unencrypted);
    try {
      await stand.initialize();
      final actual = ManagedIdentityStorage.existing(
        profileDirectory: stand.profile,
        entry: ManagedIdentityEntry.fromLocator(
          stand.master as ManagedStorageLocator,
        ),
      );
      try {
        expect(await actual.storage.openWithKeys(stand.masterKeys), isTrue);
        await actual.storage.saveRoster(stand.rows.skip(1).toList());
      } finally {
        await actual.storage.close();
      }
      expect(
        await stand.controller.createDecoyMaster(
          duressPassword: 'synthetic duress',
          includeLabels: [_Stand.labels.first],
        ),
        isFalse,
      );
      expect(stand.app.read(appControllerProvider).phase, AppPhase.locked);
      expect(stand.controller.debugRoster, isNull);
      expect(
        await stand.controller.selectStorageIdentity(stand.master),
        isTrue,
      );
      await stand.controller.unlock(stand.password);
      expect(
        stand.controller.debugRoster!.map((e) => e.label),
        _Stand.labels.skip(1),
      );
    } finally {
      await stand.close();
    }
  });

  test(
    'dispose after durable duress roster retires all temporary authority',
    () async {
      final stand = _Stand(StorageProtection.encrypted);
      Future<bool>? pending;
      try {
        await stand.initialize();
        stand.fault = _Fault(_Point.saved);
        final fault = stand.fault!;
        final controller = stand.controller;
        pending = controller.createDecoyMaster(
          duressPassword: 'synthetic duress',
          includeLabels: [_Stand.labels.first],
        );
        await Future.any<void>([
          fault.entered.future,
          pending.then(
            (_) => throw StateError('operation ended before dispose gate'),
          ),
        ]);
        final rootKeys = controller.debugMasterKeys!,
            children = controller.debugRoster!.map((e) => e.spaceKeys).toList();
        expect(children, hasLength(4));
        expect(fault.exported, hasLength(1));
        stand.app.dispose();
        stand.apps.remove(stand.app);
        fault.release.complete();
        expect(await pending, isFalse);
        expect(rootKeys, everyElement(0));
        expect(children, everyElement(everyElement(0)));
        expect(fault.exported, everyElement(everyElement(0)));
        stand.app = await stand.bind(stand.live);
        expect(
          await stand.controller.selectStorageIdentity(stand.master),
          isTrue,
        );
        await stand.controller.unlock(stand.password);
        expect(
          stand.controller.debugRoster!.map((e) => e.label),
          _Stand.labels,
        );
      } finally {
        final fault = stand.fault;
        if (fault != null && !fault.release.isCompleted) {
          fault.release.complete();
        }
        await pending;
        await stand.close();
      }
    },
  );
}
