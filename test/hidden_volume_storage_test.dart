import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';

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

  test('eraseSpace forensically clears the identity, messages, and contacts',
      () async {
    await storage.saveIdentity(Identity(nodeId: _id(1), displayName: 'Gone'));
    await storage.upsertContact(Contact(nodeId: _id(2)));
    await storage.appendMessage(_msg(
        conv: _id(2).hex,
        dir: MessageDirection.incoming,
        body: 'secret',
        ts: DateTime(2026, 5, 1)));
    expect(await storage.loadIdentity(), isNotNull);
    expect((await storage.loadMessages(_id(2).hex)).isNotEmpty, isTrue);

    await storage.eraseSpace();

    expect(await storage.loadIdentity(), isNull);
    expect(await storage.loadMessages(_id(2).hex), isEmpty);
    expect(await storage.getContact(_id(2)), isNull);
    expect(await storage.loadConversations(), isEmpty);
  });

  test('incremental log fold matches a full scan across appends + status reads',
      () async {
    final a = _id(1).hex; // conversation A (interleaved with B in the log)
    final b = _id(2).hex;
    for (var i = 0; i < 5; i++) {
      await storage.appendMessage(_msg(
          conv: i.isEven ? a : b,
          dir: MessageDirection.outgoing,
          body: 'm$i',
          ts: DateTime(2026, 5, 1, 0, i)));
    }
    // Initial fold.
    expect((await storage.loadMessages(a)).map((m) => m.body),
        ['m0', 'm2', 'm4']);
    // A status flip + a new append → exercised as INCREMENTAL folds (the read
    // above already advanced the watermark).
    final m0Id = (await storage.loadMessages(a)).first.id;
    await storage.markMessageStatus(m0Id, MessageStatus.delivered);
    await storage.appendMessage(_msg(
        conv: a,
        dir: MessageDirection.outgoing,
        body: 'm5',
        ts: DateTime(2026, 5, 1, 0, 5)));
    final after = await storage.loadMessages(a);
    expect(after.map((m) => m.body), ['m0', 'm2', 'm4', 'm5']);
    expect(after.firstWhere((m) => m.body == 'm0').status,
        MessageStatus.delivered);
    // Ground truth: a SECOND handle over the same store has a cold cache, so its
    // first read is a full scan. The incremental fold must agree byte-for-byte.
    final fresh = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) =>
          password.isEmpty ? null : store,
    );
    await fresh.open(password: 'pw');
    final truth = await fresh.loadMessages(a);
    expect(
      after.map((m) => '${m.body}:${m.status.index}').toList(),
      truth.map((m) => '${m.body}:${m.status.index}').toList(),
    );
  });

  test('open returns false for an empty password (auth-fail path)', () async {
    final fresh = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) =>
          password.isEmpty ? null : FakeKvLogStore(),
    );
    expect(await fresh.open(password: ''), isFalse);
    expect(fresh.isOpen, isFalse);
  });

  test('node config is stored in the space and survives reopen', () async {
    expect(await storage.loadNodeConfig(), isNull);
    const toml = '[Identity]\nprivate_key = "secret"\nnode_id = "abc"\n';
    await storage.saveNodeConfig(toml);
    expect(await storage.loadNodeConfig(), toml);

    // It lives in the container, not a file — a fresh handle over the same
    // backing store still reads it (deniable, no plaintext config.toml).
    final reopened = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => store,
    );
    await reopened.open(password: 'pw');
    expect(await reopened.loadNodeConfig(), toml);
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

  test('a contact with no messages still appears in the chat list', () async {
    await storage.upsertContact(Contact(nodeId: _id(5), name: 'Carol'));

    final convos = await storage.loadConversations();
    expect(convos.map((c) => c.peer.nodeId), contains(_id(5)));
    final carol = convos.firstWhere((c) => c.peer.nodeId == _id(5));
    expect(carol.peer.name, 'Carol');
    expect(carol.lastMessage, isNull);
  });

  test('unread counts incoming messages; markRead resets it', () async {
    final conv = _id(20).hex;
    await storage.appendMessage(_msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'one',
        ts: DateTime(2026, 5, 1, 10)));
    await storage.appendMessage(_msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'two',
        ts: DateTime(2026, 5, 1, 11)));
    // Our own outgoing message never counts as unread.
    await storage.appendMessage(_msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'mine',
        ts: DateTime(2026, 5, 1, 12)));

    expect((await storage.loadConversations())
        .firstWhere((c) => c.id == conv)
        .unread, 2);

    // Opening it marks read up to the latest message.
    await storage.markRead(conv);
    expect((await storage.loadConversations())
        .firstWhere((c) => c.id == conv)
        .unread, 0);

    // A newer incoming bumps unread again.
    await storage.appendMessage(_msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'three',
        ts: DateTime(2026, 5, 1, 13)));
    expect((await storage.loadConversations())
        .firstWhere((c) => c.id == conv)
        .unread, 1);
  });

  test('loadRoster is null for a plain identity space (the discriminator)',
      () async {
    expect(await storage.loadRoster(), isNull);
  });

  test('roster round-trips: labels + opaque SpaceKeys, survives reopen',
      () async {
    final entries = [
      RosterEntry(label: 'me', spaceKeys: Uint8List.fromList(List.filled(64, 1))),
      RosterEntry(
          label: 'relatives',
          spaceKeys: Uint8List.fromList(List.filled(64, 2)),
          anonymous: true),
    ];
    await storage.saveRoster(entries);

    final back = await storage.loadRoster();
    expect(back, isNotNull);
    expect(back!.map((e) => e.label), ['me', 'relatives']);
    expect(back[0].spaceKeys, entries[0].spaceKeys);
    expect(back[1].spaceKeys, entries[1].spaceKeys);
    // The per-identity anonymous-routing flag round-trips.
    expect(back[0].anonymous, isFalse);
    expect(back[1].anonymous, isTrue);

    // A fresh handle over the same backing store still reads it (lives in the
    // container, no on-disk index).
    final reopened = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => store,
    );
    await reopened.open(password: 'pw');
    expect((await reopened.loadRoster())!.map((e) => e.label), ['me', 'relatives']);
  });

  test('a messaged contact sorts above a message-less one', () async {
    await storage.upsertContact(Contact(nodeId: _id(5), name: 'Carol'));
    await storage.appendMessage(_msg(
      conv: _id(6).hex,
      dir: MessageDirection.outgoing,
      body: 'yo',
      ts: DateTime(2026, 2, 1),
    ));

    final convos = await storage.loadConversations();
    expect(convos.first.peer.nodeId, _id(6)); // has a message
    expect(convos.last.peer.nodeId, _id(5)); // message-less, at the bottom
  });

  test('editMessage replaces the body in place and marks it edited', () async {
    final conv = _id(7).hex;
    final m = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'origial',
        ts: DateTime(2026, 3, 1));
    await storage.appendMessage(m);

    await storage.editMessage(conv, m.id, 'corrected');

    final msgs = await storage.loadMessages(conv);
    expect(msgs.length, 1); // no duplicate row — last-write-wins by log_id
    expect(msgs.single.body, 'corrected');
    expect(msgs.single.edited, isTrue);
    // The prior text no longer reads back anywhere in the log.
    expect(msgs.any((x) => x.body == 'origial'), isFalse);
  });

  test('deleteMessage removes it entirely (incl. a received message)', () async {
    final conv = _id(8).hex;
    final incoming = _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'received secret',
        ts: DateTime(2026, 3, 2));
    final mine = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'keep me',
        ts: DateTime(2026, 3, 3));
    await storage.appendMessage(incoming);
    await storage.appendMessage(mine);

    await storage.deleteMessage(conv, incoming.id);

    final msgs = await storage.loadMessages(conv);
    expect(msgs.map((m) => m.body), ['keep me']);
    expect(msgs.any((m) => m.body == 'received secret'), isFalse);
  });

  test('edit/delete on an unknown id is a no-op', () async {
    await storage.editMessage(_id(9).hex, 'nope', 'x');
    await storage.deleteMessage(_id(9).hex, 'nope');
    expect(await storage.loadMessages(_id(9).hex), isEmpty);
  });

  test('deleting a file message also purges the stored blob', () async {
    final conv = _id(11).hex;
    await storage.storeFile('blob1', Uint8List.fromList([1, 2, 3, 4]),
        name: 'secret.bin');
    final m = Message(
      id: 'filemsg',
      conversationId: conv,
      direction: MessageDirection.incoming,
      body: '📎 secret.bin',
      timestamp: DateTime(2026, 3, 5),
      fileId: 'blob1',
      fileName: 'secret.bin',
    );
    await storage.appendMessage(m);
    expect(await storage.loadFile('blob1'), isNotNull);

    await storage.deleteMessage(conv, 'filemsg');
    await storage.scrubDeleted();

    expect(await storage.loadMessages(conv), isEmpty);
    expect(await storage.loadFile('blob1'), isNull); // blob gone, not just row
  });

  test('editing a delivered message preserves its delivery status', () async {
    final conv = _id(12).hex;
    final m = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'v1',
        ts: DateTime(2026, 4, 1));
    await storage.appendMessage(m);
    await storage.markMessageStatus(m.id, MessageStatus.delivered);

    await storage.editMessage(conv, m.id, 'v2');

    final msg = (await storage.loadMessages(conv)).single;
    expect(msg.body, 'v2');
    expect(msg.edited, isTrue);
    expect(msg.status, MessageStatus.delivered,
        reason: 'an edit must not reset delivery state');
  });

  test('a status update after an edit still folds onto the edited message',
      () async {
    final conv = _id(13).hex;
    final m = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'hello',
        ts: DateTime(2026, 4, 2));
    await storage.appendMessage(m);
    await storage.editMessage(conv, m.id, 'hello (fixed)');
    await storage.markMessageStatus(m.id, MessageStatus.delivered);

    final msg = (await storage.loadMessages(conv)).single;
    expect(msg.body, 'hello (fixed)');
    expect(msg.edited, isTrue);
    expect(msg.status, MessageStatus.delivered);
  });

  test('deleting the same message twice is idempotent', () async {
    final conv = _id(14).hex;
    final m = _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'gone',
        ts: DateTime(2026, 4, 3));
    await storage.appendMessage(m);

    await storage.deleteMessage(conv, m.id);
    await storage.deleteMessage(conv, m.id); // already tombstoned → no-op

    expect(await storage.loadMessages(conv), isEmpty);
  });

  test('editing a deleted message is a no-op (cannot resurrect)', () async {
    final conv = _id(15).hex;
    final m = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'secret',
        ts: DateTime(2026, 4, 4));
    await storage.appendMessage(m);
    await storage.deleteMessage(conv, m.id);

    await storage.editMessage(conv, m.id, 'resurrected?');

    expect(await storage.loadMessages(conv), isEmpty);
  });

  test('a deleted id stays gone after a scrub pass', () async {
    final conv = _id(10).hex;
    final m = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'burn after reading',
        ts: DateTime(2026, 3, 4));
    await storage.appendMessage(m);
    await storage.deleteMessage(conv, m.id);
    await storage.scrubDeleted(); // reclaim orphaned chunks

    expect(await storage.loadMessages(conv), isEmpty);
  });

  test(
      'edit/delete are conversation-scoped: naming a foreign conversation '
      'cannot touch another chat\'s message (MSGID-GLOBAL)', () async {
    // Victim's message lives in conversation A. An attacker controls a DIFFERENT
    // conversation B and (somehow) learns the victim message's id — historically
    // the index keyed on the bare id, so a del/edit driven by B's wire envelope
    // rewrote A's message. With per-conversation scoping, B naming A's id is a
    // pure no-op against A.
    final convA = _id(20).hex;
    final convB = _id(21).hex;
    final victim = Message(
      id: 'shared-id',
      conversationId: convA,
      direction: MessageDirection.incoming,
      body: 'private to A',
      timestamp: DateTime(2026, 5, 1),
    );
    await storage.appendMessage(victim);

    // Attacker in conversation B tries to erase / rewrite A's id.
    await storage.deleteMessage(convB, 'shared-id');
    await storage.editMessage(convB, 'shared-id', 'tampered by B');
    expect(await storage.isMessageDeleted(convB, 'shared-id'), isFalse,
        reason: 'B must not see A\'s message as deleted');

    // A's message is untouched.
    final inA = (await storage.loadMessages(convA)).single;
    expect(inA.body, 'private to A');
    expect(inA.edited, isFalse);

    // The legitimate owner (conversation A) CAN delete it.
    await storage.deleteMessage(convA, 'shared-id');
    expect(await storage.loadMessages(convA), isEmpty);
    expect(await storage.isMessageDeleted(convA, 'shared-id'), isTrue);
  });
}
