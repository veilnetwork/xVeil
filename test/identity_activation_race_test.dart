// Two identity switches racing each other (report24 CH-H2).
//
// `_activateOnline` re-points the view — active label, providers, stack —
// BEFORE it reads the profile, and publishes the app state AFTER. Two switches
// overlapping therefore ended with the LATER one owning storage and messaging
// while the EARLIER one's publish named its own identity on screen. Not a
// passing frame: the final state, until something else moves it. In an app
// where the identity decides the author, the recipient and the container, that
// is the interface vouching for the wrong one.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/identity.dart';
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
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _c.close();
}

/// Delegating backing that can hold ONE space's reads open.
///
/// The window is a slow profile read: the view is already re-pointed and the
/// state is not published yet. Holding one space there turns "two switches
/// happened to interleave" into a case that can be stated.
class _GatedBacking implements AsyncMultiSpaceBacking {
  _GatedBacking(this._inner);

  final AsyncMultiSpaceBacking _inner;
  int? gatedSpace;
  Completer<void>? gate;

  /// Space id per key material, so a test can gate the space the SESSION
  /// opened rather than one it opened itself — the fake hands out a fresh id
  /// per call, and gating the wrong one gates nothing at all.
  final Map<String, int> idsByKeys = {};

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _wait(int id) async {
    if (id == gatedSpace && gate != null) await gate!.future;
  }

  @override
  Future<int> openSpace(Uint8List keys) async {
    final id = await _inner.openSpace(keys);
    idsByKeys[_hex(keys)] = id;
    return id;
  }

  /// Hold the reads of the space last opened with [keys].
  void hold(Uint8List keys) {
    gatedSpace = idsByKeys[_hex(keys)];
    gate = Completer<void>();
  }
  @override
  Future<int> commit(int id, List<KvLogOp> ops) => _inner.commit(id, ops);
  @override
  Future<Uint8List?> get(int id, int namespace, Uint8List key) async {
    await _wait(id);
    return _inner.get(id, namespace, key);
  }

  @override
  Future<Uint8List?> readLog(int id, int namespace, int logId) =>
      _inner.readLog(id, namespace, logId);
  @override
  Future<List<KvLogEntry>> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _inner.iterLogRange(
    id,
    namespace: namespace,
    start: start,
    end: end,
    limit: limit,
  );
  @override
  Future<int> count(int id, int namespace) => _inner.count(id, namespace);
  @override
  Future<List<Uint8List>> kvKeys(int id, int namespace) =>
      _inner.kvKeys(id, namespace);
  @override
  Future<Uint8List> exportKeys(int id) => _inner.exportKeys(id);
  @override
  Future<void> scrub(int id) => _inner.scrub(id);
  @override
  Future<SlotUtilization?> slotUtilization(int id) =>
      _inner.slotUtilization(id);
  @override
  Future<String?> hardeningWarning(int id) => _inner.hardeningWarning(id);
  @override
  Future<void> acknowledgeHardeningWarning(int id) =>
      _inner.acknowledgeHardeningWarning(id);
  @override
  Future<void> vacuumOrphans(int id) => _inner.vacuumOrphans(id);
  @override
  Future<void> close() => _inner.close();
}

Future<void> _settle(ProviderContainer c) async {
  for (
    var i = 0;
    i < 30 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
    i++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  test('overlapping switches leave the view and the storage on ONE identity',
      () async {
    SharedPreferences.setMockInitialValues({
      'onboarded': true,
      'keep_all_online': true,
    });

    final backing = FakeMultiSpaceBacking();
    Future<void> seed(Uint8List keys, String name) async {
      final s = HiddenVolumeStorage.fromStore(
        MultiSpaceKvLogStore(backing, backing.openSpace(keys)),
      );
      await s.saveProfile(UserProfile(displayName: name));
    }

    await seed(_keys(1), 'Alice');
    await seed(_keys(2), 'Bob');
    await seed(_keys(3), 'Charlie');

    final masterContainer = FakeHvContainer();
    final master = masterContainer.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: _keys(1)),
      RosterEntry(label: 'bob', spaceKeys: _keys(2)),
      RosterEntry(label: 'charlie', spaceKeys: _keys(3)),
    ]);
    await master.close();

    final gated = _GatedBacking(SyncWrappedAsyncMultiSpaceBacking(backing));
    final session = MultiIdentitySession(
      gated,
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      boot: (spec, storage) async =>
          IdentityNode(transport: _NoopTransport(), dispose: () async {}),
    );

    final c = ProviderContainer(
      overrides: [
        singleSpaceStorageProvider.overrideWith(
          (ref) => masterContainer.storage(),
        ),
        deniableBootProvider.overrideWithValue(
          const DeniableBootConfig(
            runtimeDir: '/run',
            listenPort: 9000,
            storePath: '/x',
          ),
        ),
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
          }) => session,
        ),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    c.read(keepAllOnlineProvider);
    await _settle(c);

    await ctrl.unlock('masterpw');
    expect(c.read(appControllerProvider).phase, AppPhase.ready);

    // Hold bob's profile read open, start the switch to bob, then overtake it
    // with a switch to charlie — the shape a person produces by re-opening the
    // account sheet while a slow switch is still running.
    gated.hold(_keys(2));
    expect(gated.gatedSpace, isNotNull, reason: 'bob\'s space must be open');

    final toBob = ctrl.switchIdentity('bob');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final toCharlie = ctrl.switchIdentity('charlie');
    await toCharlie;

    // Now let bob's read finish and both switches settle.
    gated.gate!.complete();
    gated.gate = null;
    await toBob;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final view = c.read(appControllerProvider).activeIdentity;
    final pointed = c.read(activeIdentityProvider);
    expect(
      view,
      pointed,
      reason:
          'the screen named $view while storage and messaging followed $pointed',
    );
    expect(pointed, 'charlie', reason: 'the last switch is the one that counts');
    expect(
      (await c.read(storageProvider).loadProfile())!.displayName,
      'Charlie',
    );
  });
}
