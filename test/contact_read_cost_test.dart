import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

class _Store extends FakeKvLogStore {
  var contactReads = 0;
  bool failRead = false;

  @override
  Uint8List? get(int namespace, Uint8List key) {
    if (namespace == Ns.contacts) {
      contactReads++;
      if (failRead) throw StateError('synthetic contact read failure');
    }
    return super.get(namespace, key);
  }
}

NodeId _id(int tag) => NodeId(Uint8List(32)..fillRange(0, 32, tag));

void main() {
  test('reading a contact batch costs one namespace read per result', () async {
    final raw = _Store();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    for (var i = 0; i < 32; i++) {
      raw.commit([
        PutOp(
          Ns.contacts,
          _id(i).bytes,
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'name': 'Контакт $i',
                's': i % ContactStatus.values.length,
                'rd': 7,
              }),
            ),
          ),
        ),
      ]);
    }
    raw.contactReads = 0;
    for (var i = 0; i < 32; i++) {
      final contact = await storage.getContact(_id(i));
      expect(contact?.nodeId, _id(i));
      expect(contact?.name, 'Контакт $i');
      expect(
        contact?.status,
        ContactStatus.values[i % ContactStatus.values.length],
      );
      expect(contact?.retentionDays, 7);
    }
    expect(
      raw.contactReads,
      32,
      reason: 'each lookup crosses the worker boundary once',
    );
  });

  test(
    'each lookup observes additions, blocking and removal without a cache',
    () async {
      final raw = _Store();
      final storage = HiddenVolumeStorage.fromStore(raw);
      addTearDown(storage.close);
      final peer = _id(1);
      expect(await storage.getContact(peer), isNull);
      await storage.upsertContact(Contact(nodeId: peer, name: 'Before'));
      expect((await storage.getContact(peer))?.status, ContactStatus.accepted);
      await storage.setContactStatus(peer, ContactStatus.blocked);
      expect((await storage.getContact(peer))?.status, ContactStatus.blocked);
      raw.commit([DeleteOp(Ns.contacts, peer.bytes)]);
      expect(await storage.getContact(peer), isNull);
    },
  );

  test('a contact read failure is not treated as an absent record', () async {
    final raw = _Store()..failRead = true;
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    await expectLater(storage.getContact(_id(1)), throwsStateError);
    expect(raw.contactReads, 1);
  });
}
