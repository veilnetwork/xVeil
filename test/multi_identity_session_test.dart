import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
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

  void deliver(NodeId src, Uint8List payload) =>
      _inbound.add(InboundMessage(src: src, payload: payload));

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
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

void main() {
  test('planIdentityBoots assigns a distinct space/dir/port per identity',
      () async {
    final backing = SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking());
    final specs = await planIdentityBoots(
        [_e('alice', 1), _e('work', 2, anonymous: true), _e('relatives', 3)],
        backing,
        runtimeDirBase: '/run',
        listenPortBase: 9000);

    expect(specs.map((s) => s.label), ['alice', 'work', 'relatives']);
    expect(specs.map((s) => s.spaceId).toSet().length, 3);
    expect(specs.map((s) => s.listenPort), [9001, 9002, 9003]);
    expect(specs.map((s) => s.anonymous), [false, true, false]);

    // DENIABILITY: the runtime dir must be under the base but must NOT contain
    // the human-readable label (a device seized while running would otherwise
    // read identity names off the filesystem). Each is an opaque, distinct,
    // stable hash.
    for (final s in specs) {
      expect(s.runtimeDir, startsWith('/run/'));
      expect(s.runtimeDir, isNot(contains(s.label)));
      expect(s.runtimeDir.split('/').last, matches(r'^[0-9a-f]{16}$'));
    }
    expect(specs.map((s) => s.runtimeDir).toSet().length, 3); // distinct
    // Stable: same label → same opaque dir across calls.
    final again = await planIdentityBoots([_e('work', 2)], backing,
        runtimeDirBase: '/run', listenPortBase: 9000);
    expect(again.single.runtimeDir, specs[1].runtimeDir);
  });

  test('planIdentityBoots stamps the session network/routing config onto '
      'every spec (ALLONLINE)', () async {
    final backing = SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking());
    final specs = await planIdentityBoots(
        [_e('alice', 1), _e('work', 2)], backing,
        runtimeDirBase: '/run',
        listenPortBase: 9000,
        obfs4Psk: 'PSKVALUE',
        lazyMining: true);
    // Without this the all-online nodes booted with no obfs4 PSK (could not join
    // the network), no lazy-mining, and no routing — out of step with the
    // single-identity path.
    expect(specs.every((s) => s.obfs4Psk == 'PSKVALUE'), isTrue);
    expect(specs.every((s) => s.lazyMining), isTrue);
  });

  test('bootAll hosts every identity storage even when a node boot fails',
      () async {
    final session = MultiIdentitySession(
        SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
        runtimeDirBase: '/run',
        listenPortBase: 9000,
        boot: (spec, storage) async => throw StateError('no node in test'));

    await session.bootAll([_e('alice', 1), _e('bob', 2)]);

    expect(session.labels.toSet(), {'alice', 'bob'});
    final alice = session.storageFor('alice')!;
    await alice.putSetting('k', 'alice-val');
    expect(await alice.getSetting('k'), 'alice-val');
    expect(session.stackFor('alice'), isNull); // boot failed → no node
    expect(session.messagingFor('alice'), isNull);
  });

  test('each identity receives into its OWN storage (concurrent pipelines)',
      () async {
    final transports = <String, _FakeTransport>{};
    final session = MultiIdentitySession(
        SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
        runtimeDirBase: '/run', listenPortBase: 9000,
        boot: (spec, storage) async {
      final t = _FakeTransport(_nid(spec.spaceId + 100));
      transports[spec.label] = t;
      return IdentityNode(transport: t, dispose: () => t.dispose());
    });
    await session.bootAll([_e('alice', 1), _e('bob', 2)]);

    // A sender accepted by alice; deliver a message to ALICE's transport.
    final sender = _nid(7);
    await session
        .storageFor('alice')!
        .upsertContact(Contact(nodeId: sender, status: ContactStatus.accepted));
    transports['alice']!
        .deliver(sender, WireEnvelope.message('hi alice', id: 'm1').encode());
    await _pump();

    // It lands in alice's storage — and NOT in bob's (isolated pipelines).
    expect(
        (await session.storageFor('alice')!.loadMessages(sender.hex))
            .any((m) => m.body == 'hi alice'),
        isTrue);
    expect(await session.storageFor('bob')!.loadMessages(sender.hex), isEmpty);

    await session.disposeAll();
  });
}
