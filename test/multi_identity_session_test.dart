import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/embedded_node.dart' show BootstrapPeerCfg;
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/multi_identity_session.dart';

import 'support/fake_multi_space.dart';

Uint8List _keys(int seed) => Uint8List.fromList(List.filled(64, seed));
NodeId _nid(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));
RosterEntry _e(String label, int seed, {bool anonymous = false}) =>
    RosterEntry(label: label, spaceKeys: _keys(seed), anonymous: anonymous);
Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Fake transport with a manual inbound feed, so a test can deliver a message
/// to one identity's pipeline.
class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();

  void deliver(NodeId src, Uint8List payload) => _inbound.add(
    InboundMessage(
      src: src,
      payload: payload,
      provenance: SenderProvenance.sessionPeer,
    ),
  );

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;

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
  Future<void> dispose() async => _inbound.close();
}

void main() {
  test(
    'planIdentityBoots assigns a distinct space/port per identity',
    () async {
      final backing = SyncWrappedAsyncMultiSpaceBacking(
        FakeMultiSpaceBacking(),
      );
      final specs = await planIdentityBoots(
        [_e('alice', 1), _e('work', 2, anonymous: true), _e('relatives', 3)],
        backing,
        runtimeDirBase: '/run',
        listenPortBase: 9000,
      );

      expect(specs.map((s) => s.label), ['alice', 'work', 'relatives']);
      expect(specs.map((s) => s.spaceId).toSet().length, 3);
      expect(specs.map((s) => s.listenPort), [9001, 9002, 9003]);
      expect(specs.map((s) => s.anonymous), [false, true, false]);

      // DENIABILITY: the plan carries a runtime BASE, and nothing derived from
      // the human-readable label — a device seized while running would
      // otherwise read identity names off the filesystem. Each node then
      // creates its own randomly named directory under it
      // ([RuntimeDirLease]), so the names are opaque AND differ between runs;
      // the label hash this used to interpose was opaque but identical every
      // time, which correlated one run's leftovers with the next one's.
      for (final s in specs) {
        expect(s.runtimeBase, '/run');
        expect(s.runtimeBase, isNot(contains(s.label)));
      }
      final again = await planIdentityBoots(
        [_e('work', 2)],
        backing,
        runtimeDirBase: '/run',
        listenPortBase: 9000,
      );
      expect(again.single.runtimeBase, specs[1].runtimeBase);
    },
  );

  test('planIdentityBoots stamps the session network/routing config onto '
      'every spec (ALLONLINE)', () async {
    final backing = SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking());
    final specs = await planIdentityBoots(
      [_e('alice', 1), _e('work', 2)],
      backing,
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      bootstrapPeers: const [
        BootstrapPeerCfg(
          publicKey: 'seed-key',
          transport: 'quic://seed.example:443',
          nonce: '7',
          algo: 'sha256',
        ),
      ],
      obfs4Psk: 'PSKVALUE',
      udpReflectors: const ['127.0.0.1:39999'],
      lazyMining: true,
    );
    // Without this the all-online nodes booted with no obfs4 PSK (could not join
    // the network), no lazy-mining, and no routing — out of step with the
    // single-identity path.
    expect(specs.every((s) => s.obfs4Psk == 'PSKVALUE'), isTrue);
    expect(
      specs.every((s) => s.udpReflectors.single == '127.0.0.1:39999'),
      isTrue,
    );
    expect(specs.every((s) => s.lazyMining), isTrue);
    expect(specs.every((s) => s.bootstrapPeers.single.nonce == '7'), isTrue);
  });

  test(
    'bootAll hosts every identity storage even when a node boot fails',
    () async {
      final session = MultiIdentitySession(
        SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
        runtimeDirBase: '/run',
        listenPortBase: 9000,
        boot: (spec, storage) async => throw StateError('no node in test'),
      );

      await session.bootAll([_e('alice', 1), _e('bob', 2)]);

      expect(session.labels.toSet(), {'alice', 'bob'});
      final alice = session.storageFor('alice')!;
      await alice.putSetting('k', 'alice-val');
      expect(await alice.getSetting('k'), 'alice-val');
      expect(session.stackFor('alice'), isNull); // boot failed → no node
      expect(session.messagingFor('alice'), isNull);
    },
  );

  test('bootAll scrubs every space it opened, after the boots', () async {
    // The constant-time open no longer vacuums inline — doing so made a real
    // space measurably slower to open than a decoy and undid the equalized
    // scan (audit HV-02). The erase still has to happen: without this call,
    // values a previous session deleted stay decryptable to anyone who later
    // obtains the password and an old snapshot of the file.
    final fake = FakeMultiSpaceBacking();
    final session = MultiIdentitySession(
      SyncWrappedAsyncMultiSpaceBacking(fake),
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      // Every boot fails on purpose: the identity's storage stays hosted, so
      // its unlinked data is just as readable and must be scrubbed anyway.
      boot: (spec, storage) async => throw StateError('no node in test'),
    );

    await session.bootAll([_e('alice', 1), _e('bob', 2)]);

    expect(fake.opened, hasLength(2));
    expect(
      fake.vacuumed.toSet(),
      fake.opened.toSet(),
      reason: 'a space that opened but was never scrubbed keeps deleted data',
    );
  });

  test(
    'each identity receives into its OWN storage (concurrent pipelines)',
    () async {
      final transports = <String, _FakeTransport>{};
      final session = MultiIdentitySession(
        SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
        runtimeDirBase: '/run',
        listenPortBase: 9000,
        boot: (spec, storage) async {
          final t = _FakeTransport(_nid(spec.spaceId + 100));
          transports[spec.label] = t;
          return IdentityNode(transport: t, dispose: () => t.dispose());
        },
      );
      await session.bootAll([_e('alice', 1), _e('bob', 2)]);

      // A sender accepted by alice; deliver a message to ALICE's transport.
      final sender = _nid(7);
      await session
          .storageFor('alice')!
          .upsertContact(
            Contact(nodeId: sender, status: ContactStatus.accepted),
          );
      transports['alice']!.deliver(
        sender,
        WireEnvelope.message('hi alice', id: 'm1').encode(),
      );
      await _pump();

      // It lands in alice's storage — and NOT in bob's (isolated pipelines).
      expect(
        (await session.storageFor('alice')!.loadMessages(sender.hex)).any(
          (m) => m.body == 'hi alice',
        ),
        isTrue,
      );
      expect(
        await session.storageFor('bob')!.loadMessages(sender.hex),
        isEmpty,
      );

      await session.disposeAll();
    },
  );

  test('a node that boots AFTER the timeout is stopped, not stranded', () async {
    // Audit XV-05. `Future.timeout` abandons the WAIT, not the WORK: the boot
    // kept running, and a node that finished late landed nowhere — not in
    // `_nodes`, so `disposeAll` never stopped it. It kept its port, its sockets
    // and its network presence for the life of the process, invisible to the
    // only code that could shut it down.
    var disposed = 0;
    final session = MultiIdentitySession(
      SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      bootTimeout: const Duration(milliseconds: 50),
      boot: (spec, storage) async {
        // Finishes well after the session gave up on it.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final t = _FakeTransport(_nid(spec.spaceId + 100));
        return IdentityNode(transport: t, dispose: () async => disposed++);
      },
    );

    await session.bootAll([_e('alice', 1)]);
    // Gave up: no live node is registered for it.
    expect(session.labels, ['alice'], reason: 'storage view is still hosted');

    // Let the late boot land.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      disposed,
      1,
      reason: 'the late node must be stopped — nobody else can reach it',
    );
  });

  test('all-online storages get the large-file tier', () async {
    // Audit XV-02. Only the single-space boot ever called `useOnDiskTier`, so
    // in all-online mode a large file already on disk read back as MISSING and
    // a new one fell into the volume index — whose ceiling the code itself
    // warns about. Switching modes silently changed what the same identity
    // could see.
    final blobs = await Directory.systemTemp.createTemp('xveil-mis-tier');
    addTearDown(() async {
      if (await blobs.exists()) await blobs.delete(recursive: true);
    });

    final session = MultiIdentitySession(
      SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      blobRoot: blobs,
      boot: (spec, storage) async => throw StateError('no node in test'),
    );
    await session.bootAll([_e('alice', 1)]);

    // A file above the tier threshold must land on disk, not in the volume —
    // observable as ciphertext appearing under the shared blob root.
    final alice = session.storageFor('alice')! as HiddenVolumeStorage;
    // Above `kMaxStoredFileBytes` (3.8 MB) so the routing picks the tier — the
    // real threshold, not one lowered for the test.
    final bytes = Uint8List(kMaxStoredFileBytes + 1024);
    await alice.storeFilePiece(
      'big',
      0,
      1,
      bytes.length,
      bytes.length,
      bytes,
      name: 'big.bin',
    );

    expect(
      blobs.listSync(recursive: true).whereType<File>(),
      isNotEmpty,
      reason: 'without the tier this would have gone into the volume index',
    );
    expect(await alice.loadFile('big'), isNotNull);
  });

  test('a teardown that never returns still releases the container', () async {
    // Reported from a real device: storage compaction sat on "opening the
    // store" for half an hour with the repack not begun — no temp file beside
    // the container, the container still open, the node still running. The
    // chain guarded every dispose against THROWING and nothing against
    // hanging, and messaging teardown waits on the node over IPC. One wedged
    // element held the LOCK_EX for the life of the process; lock and wipe take
    // this same path.
    var closed = false;
    final session = MultiIdentitySession(
      SyncWrappedAsyncMultiSpaceBacking(_ClosingFake(() => closed = true)),
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      disposeBudget: const Duration(milliseconds: 50),
      boot: (spec, storage) async => IdentityNode(
        transport: _FakeTransport(_nid(spec.spaceId + 100)),
        // Never completes — the shape of an FFI stop waiting on a node that
        // will not answer.
        dispose: () => Completer<void>().future,
      ),
    );
    await session.bootAll([_e('alice', 1), _e('bob', 2)]);

    await session.disposeAll().timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('disposeAll never returned'),
    );
    expect(
      closed,
      isTrue,
      reason: 'the lock must be released even when a dispose hangs',
    );
    // Abandoning is the right trade and it is not free: both nodes are still
    // RUNNING — sockets open, network identity live — and their handles are
    // gone from the session, so nothing can ask them to stop again. The caller
    // is about to tell the person they are locked, which is a claim about
    // exactly that, so it must not learn this from a debug log alone.
    expect(
      session.abandonedTeardowns,
      hasLength(2),
      reason:
          'two node disposes were abandoned and the session reported none — '
          '"locked" would then be said with two nodes still on the network',
    );
    expect(
      session.abandonedTeardowns.every((step) => step.startsWith('node')),
      isTrue,
      reason: 'the report must name which step was abandoned, not just count',
    );
  });

  test('a teardown that finishes reports nothing abandoned', () async {
    // The other half, and the reason it is here: a report that is never empty
    // is a report nobody can act on. Same shape as above with a dispose that
    // returns.
    var stopped = 0;
    final session = MultiIdentitySession(
      SyncWrappedAsyncMultiSpaceBacking(_ClosingFake(() {})),
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      disposeBudget: const Duration(milliseconds: 50),
      boot: (spec, storage) async => IdentityNode(
        transport: _FakeTransport(_nid(spec.spaceId + 100)),
        dispose: () async => stopped++,
      ),
    );
    await session.bootAll([_e('alice', 1), _e('bob', 2)]);
    await session.disposeAll();
    expect(stopped, 2);
    expect(session.abandonedTeardowns, isEmpty);
  });
}

/// Records that the shared container was closed — the fake is a no-op there,
/// and closing IS the property under test.
class _ClosingFake extends FakeMultiSpaceBacking {
  _ClosingFake(this.onClose);
  final void Function() onClose;

  @override
  void close() => onClose();
}
