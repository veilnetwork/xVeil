import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';

import 'support/fake_multi_space.dart';

Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));
Uint8List _keys(int seed) => Uint8List.fromList(List.filled(64, seed));
NodeId _nid(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

void main() {
  test('two views over one backing are isolated and both usable at once', () {
    final backing = FakeMultiSpaceBacking();
    final a = MultiSpaceKvLogStore(backing, backing.openSpace(_keys(1)));
    final b = MultiSpaceKvLogStore(backing, backing.openSpace(_keys(2)));

    // Interleaved writes — no lock conflict (the Phase 3 win).
    a.commit([PutOp(1, _k('who'), _k('alice'))]);
    b.commit([PutOp(1, _k('who'), _k('bob'))]);
    a.commit([PutOp(1, _k('city'), _k('riga'))]);

    expect(a.get(1, _k('who')), _k('alice'));
    expect(b.get(1, _k('who')), _k('bob'));
    expect(a.get(1, _k('city')), _k('riga'));
    expect(b.get(1, _k('city')), isNull, reason: 'B never wrote city');
  });

  test('closing one view does not affect the others (shared backing)', () {
    final backing = FakeMultiSpaceBacking();
    final a = MultiSpaceKvLogStore(backing, backing.openSpace(_keys(1)));
    final b = MultiSpaceKvLogStore(backing, backing.openSpace(_keys(2)));
    b.commit([PutOp(1, _k('who'), _k('bob'))]);

    a.close(); // view close is a no-op on the shared backing
    expect(b.get(1, _k('who')), _k('bob'));
  });

  test('two HiddenVolumeStorage identities run over one backing at once',
      () async {
    final backing = FakeMultiSpaceBacking();
    final alice = HiddenVolumeStorage.fromStore(
        MultiSpaceKvLogStore(backing, backing.openSpace(_keys(1))));
    final bob = HiddenVolumeStorage.fromStore(
        MultiSpaceKvLogStore(backing, backing.openSpace(_keys(2))));
    final conv = _nid(9).hex;

    // Both identities active simultaneously — each writes its OWN data.
    await alice.saveIdentity(Identity(nodeId: _nid(1), displayName: 'Alice'));
    await bob.saveIdentity(Identity(nodeId: _nid(2), displayName: 'Bob'));
    await alice.appendMessage(_msg(conv, 'hi from alice'));
    await bob.appendMessage(_msg(conv, 'hi from bob'));

    expect((await alice.loadIdentity())!.displayName, 'Alice');
    expect((await bob.loadIdentity())!.displayName, 'Bob');
    expect((await alice.loadMessages(conv)).single.body, 'hi from alice');
    expect((await bob.loadMessages(conv)).single.body, 'hi from bob');
  });
}

Message _msg(String conv, String body) => Message(
      id: body,
      conversationId: conv,
      direction: MessageDirection.outgoing,
      body: body,
      timestamp: DateTime(2026, 6, 15),
    );
