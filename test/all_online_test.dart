import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/keep_all_online_controller.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';
import 'support/fake_multi_space.dart';

Uint8List _keys(int seed) => Uint8List.fromList(List.filled(64, seed));

class _NoopTransport implements VeilTransport {
  final _c = StreamController<InboundMessage>.broadcast();
  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => _c.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> dispose() async => _c.close();
}

Future<void> _settle(ProviderContainer c) async {
  for (var i = 0; i < 30 && c.read(appControllerProvider).phase == AppPhase.bootstrapping; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  // Let the keepAllOnline pref load too.
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  test('all-online: master unlock boots all identities; switch repoints; '
      'lock disposes', () async {
    SharedPreferences.setMockInitialValues(
        {'onboarded': true, 'keep_all_online': true});

    // Shared multi-space backing; pre-seed two child identities into it.
    final backing = FakeMultiSpaceBacking();
    Future<void> seed(Uint8List keys, String name) async {
      final s = HiddenVolumeStorage.fromStore(
          MultiSpaceKvLogStore(backing, backing.openSpace(keys)));
      await s.saveIdentity(AppController.generateIdentity(displayName: name));
    }
    await seed(_keys(1), 'Alice');
    await seed(_keys(2), 'Bob');

    // The master single-space holds the roster pointing at those child keys.
    final masterContainer = FakeHvContainer();
    final master = masterContainer.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: _keys(1)),
      RosterEntry(label: 'bob', spaceKeys: _keys(2)),
    ]);
    await master.close();

    // A session over the shared backing with a no-node fake boot.
    final session = MultiIdentitySession(backing,
        runtimeDirBase: '/run', listenPortBase: 9000,
        boot: (spec, storage) async =>
            IdentityNode(transport: _NoopTransport(), dispose: () async {}));

    final c = ProviderContainer(overrides: [
      singleSpaceStorageProvider.overrideWith((ref) => masterContainer.storage()),
      deniableBootProvider.overrideWithValue(const DeniableBootConfig(
          runtimeDir: '/run', listenPort: 9000, storePath: '/x')),
      sessionBuilderProvider.overrideWithValue(
          ({required storePath, required runtimeDir, required listenPort}) =>
              session),
    ]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    c.read(keepAllOnlineProvider); // kick its async load
    await _settle(c);
    expect(c.read(keepAllOnlineProvider), isTrue);

    // Unlock the master → all identities online, first one shown.
    await ctrl.unlock('masterpw');
    final s = c.read(appControllerProvider);
    expect(s.phase, AppPhase.ready);
    expect(s.identities.toSet(), {'alice', 'bob'});
    expect(ctrl.activeIdentity, 'alice');
    expect(s.identity!.displayName, 'Alice');
    expect(c.read(sessionProvider), isNotNull);
    // storageProvider now resolves to the ACTIVE identity's storage.
    expect((await c.read(storageProvider).loadIdentity())!.displayName, 'Alice');

    // Switch to bob — repoint the view, no teardown.
    await ctrl.switchIdentity('bob');
    expect(c.read(appControllerProvider).identity!.displayName, 'Bob');
    expect(c.read(activeIdentityProvider), 'bob');
    expect((await c.read(storageProvider).loadIdentity())!.displayName, 'Bob');

    // Lock disposes the session.
    await ctrl.lock();
    expect(c.read(appControllerProvider).phase, AppPhase.locked);
    expect(c.read(sessionProvider), isNull);
  });

  test('keepAllOnline off → master unlock uses the picker (one-active)',
      () async {
    SharedPreferences.setMockInitialValues(
        {'onboarded': true, 'keep_all_online': false});
    final masterContainer = FakeHvContainer();
    final m = masterContainer.storage();
    await m.open(password: 'masterpw', createIfMissing: true);
    await m.saveRoster([RosterEntry(label: 'alice', spaceKeys: _keys(1))]);
    await m.close();

    final c = ProviderContainer(overrides: [
      singleSpaceStorageProvider.overrideWith((ref) => masterContainer.storage()),
      deniableBootProvider.overrideWithValue(const DeniableBootConfig(
          runtimeDir: '/run', listenPort: 9000, storePath: '/x')),
    ]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await _settle(c);

    await ctrl.unlock('masterpw');
    expect(c.read(appControllerProvider).phase, AppPhase.pickingIdentity);
    expect(c.read(sessionProvider), isNull);
  });

  test('all-online: setIdentityAnonymous toggles a background identity, '
      'rebuilds the session, restores the active view, persists to master',
      () async {
    SharedPreferences.setMockInitialValues(
        {'onboarded': true, 'keep_all_online': true});
    final backing = FakeMultiSpaceBacking();
    Future<void> seed(Uint8List keys, String name) async {
      final s = HiddenVolumeStorage.fromStore(
          MultiSpaceKvLogStore(backing, backing.openSpace(keys)));
      await s.saveIdentity(AppController.generateIdentity(displayName: name));
    }
    await seed(_keys(1), 'Alice');
    await seed(_keys(2), 'Bob');

    final masterContainer = FakeHvContainer();
    final master = masterContainer.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: _keys(1)),
      RosterEntry(label: 'bob', spaceKeys: _keys(2)),
    ]);
    await master.close();

    // Fresh session over the SAME (persistent) backing on each build — mirrors
    // production, where each session reopens the container file. Editing the
    // master roster tears the session down, so the rebuild must work.
    MultiIdentitySession build() => MultiIdentitySession(backing,
        runtimeDirBase: '/run',
        listenPortBase: 9000,
        boot: (spec, storage) async =>
            IdentityNode(transport: _NoopTransport(), dispose: () async {}));

    final c = ProviderContainer(overrides: [
      singleSpaceStorageProvider
          .overrideWith((ref) => masterContainer.storage()),
      deniableBootProvider.overrideWithValue(const DeniableBootConfig(
          runtimeDir: '/run', listenPort: 9000, storePath: '/x')),
      sessionBuilderProvider.overrideWithValue(
          ({required storePath, required runtimeDir, required listenPort}) =>
              build()),
    ]);
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    c.read(keepAllOnlineProvider);
    await _settle(c);

    await ctrl.unlock('masterpw');
    expect(ctrl.activeIdentity, 'alice');
    expect(ctrl.isIdentityAnonymous('bob'), isFalse);

    // Toggle a BACKGROUND identity (bob) anonymous while alice is active.
    expect(await ctrl.setIdentityAnonymous('bob', true), isTrue);
    expect(ctrl.isIdentityAnonymous('bob'), isTrue);
    // Session rebuilt (all-online restored), previously-active view (alice) kept.
    expect(c.read(sessionProvider), isNotNull);
    expect(ctrl.activeIdentity, 'alice');

    // Persisted to the master on disk.
    await ctrl.lock();
    final check = masterContainer.storage();
    await check.open(password: 'masterpw');
    final bob =
        (await check.loadRoster())!.firstWhere((e) => e.label == 'bob');
    await check.close();
    expect(bob.anonymous, isTrue);
  });
}
