import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

Message _msg({
  required String conv,
  required MessageDirection dir,
  required String body,
  required DateTime ts,
}) =>
    Message(
      id: '$body-${ts.millisecondsSinceEpoch}',
      conversationId: conv,
      direction: dir,
      body: body,
      timestamp: ts,
    );

void main() {
  late FakeKvLogStore store;
  late HiddenVolumeStorage storage;

  setUp(() async {
    store = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) =>
          password.isEmpty ? null : store,
    );
    await storage.open(password: 'pw', createIfMissing: true);
  });

  test('open returns false for an empty password (auth-fail path)', () async {
    final fresh = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) =>
          password.isEmpty ? null : FakeKvLogStore(),
    );
    expect(await fresh.open(password: ''), isFalse);
    expect(fresh.isOpen, isFalse);
  });

  test('identity round-trips through the SETTINGS namespace', () async {
    final id = Identity(nodeId: _id(7), displayName: 'Alice', username: 'al');
    await storage.saveIdentity(id);

    final loaded = await storage.loadIdentity();
    expect(loaded, isNotNull);
    expect(loaded!.nodeId, _id(7));
    expect(loaded.displayName, 'Alice');
    expect(loaded.username, 'al');
  });

  test('settings round-trip', () async {
    await storage.putSetting('theme', 'dark');
    expect(await storage.getSetting('theme'), 'dark');
    expect(await storage.getSetting('missing'), isNull);
  });

  test('messages append to the log and read back in time order', () async {
    final conv = _id(1).hex;
    await storage.appendMessage(_msg(
      conv: conv,
      dir: MessageDirection.outgoing,
      body: 'first',
      ts: DateTime(2026, 1, 1, 10),
    ));
    await storage.appendMessage(_msg(
      conv: conv,
      dir: MessageDirection.incoming,
      body: 'second',
      ts: DateTime(2026, 1, 1, 11),
    ));

    final msgs = await storage.loadMessages(conv);
    expect(msgs.map((m) => m.body), ['first', 'second']);
    expect(msgs.last.direction, MessageDirection.incoming);

    // Two messages => two distinct log ids (counter advanced).
    expect(store.iterLogRange(namespace: Ns.messageLog, limit: 100).length, 2);
  });

  test('conversations are derived from the log, newest first', () async {
    final a = _id(1).hex;
    final b = _id(2).hex;
    await storage.upsertContact(Contact(nodeId: _id(2), name: 'Bob'));

    await storage.appendMessage(_msg(
      conv: a,
      dir: MessageDirection.outgoing,
      body: 'hi a',
      ts: DateTime(2026, 1, 1, 9),
    ));
    await storage.appendMessage(_msg(
      conv: b,
      dir: MessageDirection.outgoing,
      body: 'hi b',
      ts: DateTime(2026, 1, 1, 12),
    ));

    final convos = await storage.loadConversations();
    expect(convos.length, 2);
    // b is newer -> first; and its contact name resolved from CONTACTS.
    expect(convos.first.peer.nodeId, _id(2));
    expect(convos.first.peer.name, 'Bob');
    expect(convos.first.lastMessage?.body, 'hi b');
    // a has no stored contact -> falls back to the node id short label.
    expect(convos.last.peer.nodeId, _id(1));
  });

  test('data survives a lock/unlock cycle (same session store)', () async {
    await storage.putSetting('k', 'v');
    await storage.close();
    expect(storage.isOpen, isFalse);

    await storage.open(password: 'pw');
    expect(await storage.getSetting('k'), 'v');
  });
}
