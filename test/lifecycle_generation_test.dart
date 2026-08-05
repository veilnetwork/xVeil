import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/worker_death.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/keep_all_online_controller.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';
import 'support/fake_multi_space.dart';

/// H-06 — the lifecycle generation.
///
/// Every boot in [AppController] publishes what it built into a provider AFTER
/// an await, and `lock()` sits squarely inside that window: it is reachable
/// from the tray and from the API, and the window is the whole node boot,
/// first-run mining included. A lock that landed there read the providers,
/// found them empty, tore down nothing and reported the app locked — and then
/// the boot it never saw finished and published a LIVE node and an OPEN
/// container behind the lock screen, with the phase walking back to `ready`.
///
/// Both directions are pinned, and every rollback test is paired with the
/// control that the SAME boot, left alone, still reaches `ready`: "the node
/// stays off" is trivially satisfiable by breaking the boot outright.

Uint8List _keys(int seed) => Uint8List.fromList(List.filled(64, seed));

class _NoopTransport implements VeilTransport {
  final _c = StreamController<InboundMessage>.broadcast();
  var disposed = 0;

  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => _c.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
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
  Future<void> dispose() async {
    disposed++;
    await _c.close();
  }
}

class _StubNode implements NodeController {
  var stopped = 0;
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
  @override
  Future<void> stop() async => stopped++;
}

/// Records whether the shared container lock was released: `disposeAll` ends in
/// `_backing.close()`, and that flock is what the next unlock needs back.
class _RecordingBacking implements AsyncMultiSpaceBacking {
  _RecordingBacking(this._inner);
  final MultiSpaceBacking _inner;
  var closed = 0;

  @override
  Future<int> openSpace(Uint8List keys) async => _inner.openSpace(keys);
  @override
  Future<int> commit(int id, List<KvLogOp> ops) async => _inner.commit(id, ops);
  @override
  Future<Uint8List?> get(int id, int namespace, Uint8List key) async =>
      _inner.get(id, namespace, key);
  @override
  Future<Uint8List?> readLog(int id, int namespace, int logId) async =>
      _inner.readLog(id, namespace, logId);
  @override
  Future<List<KvLogEntry>> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) async => _inner.iterLogRange(
    id,
    namespace: namespace,
    start: start,
    end: end,
    limit: limit,
  );
  @override
  Future<int> count(int id, int namespace) async => _inner.count(id, namespace);
  @override
  Future<List<Uint8List>> kvKeys(int id, int namespace) async =>
      _inner.kvKeys(id, namespace);
  @override
  Future<Uint8List> exportKeys(int id) async => _inner.exportKeys(id);
  @override
  Future<void> scrub(int id) async => _inner.scrub(id);
  @override
  Future<SlotUtilization?> slotUtilization(int id) async =>
      _inner.slotUtilization(id);
  @override
  Future<void> vacuumOrphans(int id) async => _inner.vacuumOrphans(id);
  @override
  Future<void> close() async {
    closed++;
    _inner.close();
  }
}

BootstrapInvite _invite() =>
    BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8));

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

/// Wait until the boot under test has actually parked in its window.
Future<void> _pumpUntil(bool Function() ready, String what) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue, reason: 'never reached: $what');
}

typedef _OneActive = ({
  ProviderContainer container,
  AppController controller,
  _NoopTransport transport,
  _StubNode node,
  Completer<void> gate,
  bool Function() booting,
});

_OneActive _oneActiveHarness() {
  SharedPreferences.setMockInitialValues({'onboarded': true});
  final fake = FakeHvContainer();
  final c = ProviderContainer(
    overrides: [
      singleSpaceStorageProvider.overrideWith((ref) => fake.storage()),
      deniableBootProvider.overrideWithValue(
        const DeniableBootConfig(
          runtimeDir: '/run',
          listenPort: 9000,
          storePath: '/x',
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  final ctrl = c.read(appControllerProvider.notifier);
  final transport = _NoopTransport();
  final node = _StubNode();
  final gate = Completer<void>();
  var entered = false;
  ctrl.debugDeniableStackStarter = () async {
    entered = true;
    await gate.future;
    return RealVeilStack.overParts(
      controller: node,
      transport: transport,
      myInvite: _invite(),
    );
  };
  return (
    container: c,
    controller: ctrl,
    transport: transport,
    node: node,
    gate: gate,
    booting: () => entered,
  );
}

Future<void> _seedSingleIdentity(ProviderContainer c) async {
  final storage = c.read(singleSpaceStorageProvider);
  await storage.open(password: 'pw', createIfMissing: true);
  await storage.saveProfile(UserProfile(displayName: 'Solo'));
  await storage.close();
}

typedef _AllOnline = ({
  ProviderContainer container,
  AppController controller,
  _RecordingBacking backing,
  List<String> disposedNodes,
  Completer<void> gate,
  bool Function() booting,
});

Future<_AllOnline> _allOnlineHarness() async {
  SharedPreferences.setMockInitialValues({
    'onboarded': true,
    'keep_all_online': true,
  });
  final raw = FakeMultiSpaceBacking();
  Future<void> seed(Uint8List keys, String name) async {
    final s = HiddenVolumeStorage.fromStore(
      MultiSpaceKvLogStore(raw, raw.openSpace(keys)),
    );
    await s.saveProfile(UserProfile(displayName: name));
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

  final backing = _RecordingBacking(raw);
  final gate = Completer<void>();
  final disposedNodes = <String>[];
  var entered = false;
  final session = MultiIdentitySession(
    backing,
    runtimeDirBase: '/run',
    listenPortBase: 9000,
    boot: (spec, storage) async {
      entered = true;
      await gate.future;
      return IdentityNode(
        transport: _NoopTransport(),
        dispose: () async => disposedNodes.add(spec.label),
      );
    },
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
          required bootstrapPeers,
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
  c.read(keepAllOnlineProvider); // kick its async load
  await _settle(c);
  return (
    container: c,
    controller: ctrl,
    backing: backing,
    disposedNodes: disposedNodes,
    gate: gate,
    booting: () => entered,
  );
}

void main() {
  test('one-active: a lock during the node boot leaves the node OFF and the '
      'container closed — the boot refuses to publish itself', () async {
    final h = _oneActiveHarness();
    final c = h.container;
    await _settle(c);
    await _seedSingleIdentity(c);

    final unlocking = h.controller.unlock('pw');
    // Parked inside the boot: the stack exists nowhere yet, exactly as during a
    // real first-run mine.
    await _pumpUntil(h.booting, 'the deniable node boot');

    // The lock lands in the window. Before the fix it found `realStackProvider`
    // empty, tore nothing down, and returned "locked".
    await h.controller.lock();
    expect(c.read(appControllerProvider).phase, AppPhase.locked);

    // ...and NOW the node finishes coming up.
    h.gate.complete();
    await unlocking;

    expect(
      c.read(realStackProvider),
      isNull,
      reason: 'a live node was published into a session the user had ended',
    );
    expect(
      h.transport.disposed,
      1,
      reason: 'the node that came up after the lock was left on the network',
    );
    expect(h.node.stopped, 1, reason: 'the node was left running');
    expect(
      c.read(appControllerProvider).phase,
      AppPhase.locked,
      reason: 'the phase walked back off the lock screen after locking',
    );
    expect(
      c.read(singleSpaceStorageProvider).isOpen,
      isFalse,
      reason: 'the deniable container stayed open behind the lock screen',
    );
  });

  test('one-active CONTROL: with no lock the same boot reaches ready and the '
      'node IS published', () async {
    final h = _oneActiveHarness();
    final c = h.container;
    await _settle(c);
    await _seedSingleIdentity(c);

    h.gate.complete();
    await h.controller.unlock('pw');

    expect(c.read(appControllerProvider).phase, AppPhase.ready);
    expect(c.read(realStackProvider), isNotNull);
    expect(h.transport.disposed, 0);
    expect(h.node.stopped, 0);
  });

  test('all-online: a lock during bootAll disposes the session instead of '
      'publishing it — no node stays up, the shared lock goes back', () async {
    final h = await _allOnlineHarness();
    final c = h.container;

    final unlocking = h.controller.unlock('masterpw');
    await _pumpUntil(h.booting, 'the all-online node boot');

    await h.controller.lock();
    expect(c.read(appControllerProvider).phase, AppPhase.locked);

    h.gate.complete();
    await unlocking;

    expect(
      c.read(sessionProvider),
      isNull,
      reason:
          'a session owning every identity\'s node was published after the '
          'lock that was supposed to reclaim it',
    );
    expect(
      h.disposedNodes.toSet(),
      {'alice', 'bob'},
      reason: 'always-online nodes stayed on the network after the lock',
    );
    expect(
      h.backing.closed,
      greaterThan(0),
      reason: 'the container\'s shared lock was never released',
    );
    expect(c.read(appControllerProvider).phase, AppPhase.locked);
  });

  test('all-online CONTROL: with no lock the same boot reaches ready and the '
      'session IS published', () async {
    final h = await _allOnlineHarness();
    final c = h.container;

    h.gate.complete();
    await h.controller.unlock('masterpw');

    expect(c.read(appControllerProvider).phase, AppPhase.ready);
    expect(c.read(sessionProvider), isNotNull);
    expect(h.disposedNodes, isEmpty);
    expect(h.backing.closed, 0);
  });

  // ── The twin the report did not connect: the worker's own spawn window ────

  test('twin: closing while the worker is still spawning shuts THAT worker '
      'down instead of orphaning it with the container open', () async {
    // The hidden-volume library cannot load in a test VM (a spawned worker dies
    // on `dlsym` before it opens anything), so the worker comes up through the
    // seam. What is under test is the DECISION in _spawn, not the spawn.
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);

    WorkerMultiSpaceBacking.debugBringUpWorker = (path, tag) =>
        _spawnStubWorker(events.sendPort);
    addTearDown(() => WorkerMultiSpaceBacking.debugBringUpWorker = null);

    final backing = WorkerMultiSpaceBacking('/unused');
    // Starts the spawn and parks; nothing is published yet. The outcome handler
    // goes on immediately — the rollback rejects it, and an unwatched rejection
    // would be reported as an unhandled error rather than as this test's data.
    final outcome = backing
        .openSpace(_keys(1))
        .then<Object>((_) => 'published', onError: (Object e) => e);

    // close() lands INSIDE the spawn window — the shape that used to kill a
    // null isolate and return, leaving the real worker holding the container.
    await backing.close();

    expect(
      seen,
      contains('close-requested'),
      reason:
          'the worker was orphaned: it finished opening the container and kept '
          'its exclusive flock, with no reference to it left anywhere',
    );
    expect(await outcome, isA<StateError>());
  });

  test('twin CONTROL: a worker that finishes spawning with no close pending is '
      'published, and its close still reaches it', () async {
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);
    WorkerMultiSpaceBacking.debugBringUpWorker = (path, tag) =>
        _spawnStubWorker(events.sendPort);
    addTearDown(() => WorkerMultiSpaceBacking.debugBringUpWorker = null);

    final backing = WorkerMultiSpaceBacking('/unused');
    // The stub's answer is not a real reply object, so this settles as an
    // error — irrelevant here, and consumed so it is not reported as unhandled.
    // What matters is that the request REACHED the worker at all.
    final settled = backing
        .openSpace(_keys(1))
        .then<Object>((_) => 'ok', onError: (Object e) => e);

    await _pumpUntil(
      () => seen.contains('call'),
      'the request reaching the worker (i.e. the spawn published)',
    );
    expect(seen, isNot(contains('close-requested')));

    await backing.close();
    expect(seen, contains('close-requested'));
    await settled;
  });
}

/// A worker isolate that speaks just enough of the protocol to be shut down: it
/// reports on [events] what was asked of it and answers a close. Needs no
/// native library, which is the whole point.
Future<LiveMultiSpaceWorker> _spawnStubWorker(SendPort events) async {
  final boot = ReceivePort();
  final death = WorkerDeath();
  final isolate = await Isolate.spawn<List<Object>>(
    _stubWorkerEntry,
    [boot.sendPort, events],
    errorsAreFatal: true,
    onExit: death.exitPort.sendPort,
    onError: death.errorPort.sendPort,
  );
  final port = await boot.first as SendPort;
  boot.close();
  return (isolate: isolate, port: port, watch: death);
}

void _stubWorkerEntry(List<Object> args) {
  final boot = args[0] as SendPort;
  final events = args[1] as SendPort;
  final rx = ReceivePort();
  boot.send(rx.sendPort);
  rx.listen((dynamic msg) {
    // `reply` is a public field on the (library-private) request classes, so it
    // is reachable dynamically without importing them.
    final reply = (msg as dynamic).reply as SendPort;
    if (msg.runtimeType.toString().contains('Close')) {
      events.send('close-requested');
      reply.send(true);
      rx.close();
      Isolate.current.kill(priority: Isolate.immediate);
      return;
    }
    // Ordinary request: report that it arrived and answer with something the
    // backing will reject on the cast. Proving the request REACHED the worker
    // is the whole job here.
    events.send('call');
    reply.send(true);
  });
}
