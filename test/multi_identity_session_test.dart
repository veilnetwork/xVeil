import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
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
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {}
  @override
  Future<void> dispose() async => _inbound.close();
}

void main() {
  test('planIdentityBoots assigns a distinct space/dir/port per identity', () {
    final backing = FakeMultiSpaceBacking();
    final specs = planIdentityBoots(
        [_e('alice', 1), _e('work', 2, anonymous: true), _e('relatives', 3)],
        backing,
        runtimeDirBase: '/run',
        listenPortBase: 9000);

    expect(specs.map((s) => s.label), ['alice', 'work', 'relatives']);
    expect(specs.map((s) => s.spaceId).toSet().length, 3);
    expect(specs.map((s) => s.listenPort), [9001, 9002, 9003]);
    expect(specs[1].runtimeDir, '/run/work');
    expect(specs.map((s) => s.anonymous), [false, true, false]);
  });

  test('bootAll hosts every identity storage even when a node boot fails',
      () async {
    final session = MultiIdentitySession(FakeMultiSpaceBacking(),
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
    final session = MultiIdentitySession(FakeMultiSpaceBacking(),
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
