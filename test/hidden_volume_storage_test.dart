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
}) => Message(
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

  test(
    'eraseSpace forensically clears the identity, messages, and contacts',
    () async {
      await storage.saveIdentity(Identity(nodeId: _id(1), displayName: 'Gone'));
      await storage.upsertContact(Contact(nodeId: _id(2)));
      await storage.appendMessage(
        _msg(
          conv: _id(2).hex,
          dir: MessageDirection.incoming,
          body: 'secret',
          ts: DateTime(2026, 5, 1),
        ),
      );
      expect(await storage.loadIdentity(), isNotNull);
      expect((await storage.loadMessages(_id(2).hex)).isNotEmpty, isTrue);

      await storage.eraseSpace();

      expect(await storage.loadIdentity(), isNull);
      expect(await storage.loadMessages(_id(2).hex), isEmpty);
      expect(await storage.getContact(_id(2)), isNull);
      expect(await storage.loadConversations(), isEmpty);
    },
  );

  test(
    'a pinned conversation sorts above more-recent unpinned ones',
    () async {
      // Two contacts: _id(2) has the newer message, _id(3) is pinned but older.
      await storage.upsertContact(Contact(nodeId: _id(2)));
      await storage.upsertContact(Contact(nodeId: _id(3), pinned: true));
      await storage.appendMessage(
        _msg(
          conv: _id(3).hex,
          dir: MessageDirection.incoming,
          body: 'older-pinned',
          ts: DateTime(2026, 5, 1),
        ),
      );
      await storage.appendMessage(
        _msg(
          conv: _id(2).hex,
          dir: MessageDirection.incoming,
          body: 'newer-unpinned',
          ts: DateTime(2026, 5, 9),
        ),
      );

      final convs = await storage.loadConversations();
      expect(convs.first.peer.nodeId, _id(3),
          reason: 'the pinned conversation must lead despite its older message');
      expect(convs.first.peer.pinned, isTrue);

      // Unpinning restores recency order (newer conversation leads).
      await storage.upsertContact(Contact(nodeId: _id(3), pinned: false));
      final after = await storage.loadConversations();
      expect(after.first.peer.nodeId, _id(2));
    },
  );

  test(
    'clearMessages erases history but KEEPS the contact and chat-list entry',
    () async {
      await storage.upsertContact(
        Contact(nodeId: _id(2), status: ContactStatus.accepted),
      );
      await storage.appendMessage(
        _msg(
          conv: _id(2).hex,
          dir: MessageDirection.incoming,
          body: 'one',
          ts: DateTime(2026, 5, 1),
        ),
      );
      await storage.appendMessage(
        _msg(
          conv: _id(2).hex,
          dir: MessageDirection.outgoing,
          body: 'two',
          ts: DateTime(2026, 5, 2),
        ),
      );
      expect((await storage.loadMessages(_id(2).hex)).length, 2);

      await storage.clearMessages(_id(2));

      // Messages gone, contact + conversation kept (chat stays, emptied).
      expect(await storage.loadMessages(_id(2).hex), isEmpty);
      final contact = await storage.getContact(_id(2));
      expect(contact, isNotNull);
      expect(contact!.status, ContactStatus.accepted);
      expect((await storage.loadConversations()).length, 1);

      // Cleared messages must not resurrect on a re-delivery (deniable erase).
      expect(
        await storage.isMessageDeleted(
          _id(2).hex,
          'one-${DateTime(2026, 5, 1).millisecondsSinceEpoch}',
        ),
        isTrue,
      );
    },
  );

  test(
    'appended rows carry (author, seq) with independent per-author gap-free seq',
    () async {
      final c = _id(7).hex;
      // A bare row (no author) defaults its author to the conversation peer and
      // is assigned the next per-(conv,author) seq.
      await storage.appendMessage(
        Message(
          id: 'p0',
          conversationId: c,
          direction: MessageDirection.incoming,
          body: 'p0',
          timestamp: DateTime(2026, 6, 1, 0, 0),
        ),
      );
      // Two explicit authors in the SAME conversation get INDEPENDENT, gap-free
      // streams (event-log §15.4 R4/R10).
      Message ev(String id, String author, DateTime ts) => Message(
            id: id,
            conversationId: c,
            direction: MessageDirection.outgoing,
            body: id,
            timestamp: ts,
            author: author,
          );
      await storage.appendMessage(ev('a1', 'AAAA', DateTime(2026, 6, 1, 0, 1)));
      await storage.appendMessage(ev('b1', 'BBBB', DateTime(2026, 6, 1, 0, 2)));
      await storage.appendMessage(ev('a2', 'AAAA', DateTime(2026, 6, 1, 0, 3)));

      final msgs = {for (final m in await storage.loadMessages(c)) m.id: m};
      expect(msgs['p0']!.author, c); // defaulted to the peer
      expect(msgs['p0']!.seq, 1); // first in (c, c)
      expect(msgs['a1']!.author, 'AAAA');
      expect(msgs['a1']!.seq, 1); // first in (c, AAAA)
      expect(msgs['a2']!.seq, 2); // second in (c, AAAA) — gap-free
      expect(msgs['b1']!.author, 'BBBB');
      expect(msgs['b1']!.seq, 1); // first in (c, BBBB) — independent stream
    },
  );

  test(
    'edit retains every version as history; the fold shows the latest',
    () async {
      final c = _id(8).hex;
      await storage.appendMessage(
        Message(
          id: 'h1',
          conversationId: c,
          direction: MessageDirection.outgoing,
          body: 'v1',
          timestamp: DateTime(2026, 6, 1, 0, 0),
          author: 'ME',
        ),
      );
      await storage.editMessage(c, 'h1', 'v2');
      await storage.editMessage(c, 'h1', 'v3');

      // Display (fold) shows only the latest, flagged edited.
      final current = (await storage.loadMessages(c)).single;
      expect(current.body, 'v3');
      expect(current.edited, isTrue);

      // History retains every version, oldest-first, with the original flagged.
      final hist = await storage.loadMessageHistory(c, 'h1');
      expect(hist.map((v) => v.body).toList(), ['v1', 'v2', 'v3']);
      expect(hist.first.isOriginal, isTrue);
      expect(hist[1].isOriginal, isFalse);
      expect(hist.last.isOriginal, isFalse);
      expect(hist.every((v) => v.author == 'ME'), isTrue);

      // A deleted message exposes no history.
      await storage.deleteMessage(c, 'h1');
      expect(await storage.loadMessageHistory(c, 'h1'), isEmpty);
    },
  );

  test(
    'loadMessages limit returns the most-recent window, oldest-first',
    () async {
      final c = _id(3).hex;
      for (var i = 0; i < 10; i++) {
        await storage.appendMessage(
          _msg(
            conv: c,
            dir: MessageDirection.outgoing,
            body: 'p$i',
            ts: DateTime(2026, 6, 1, 0, i),
          ),
        );
      }
      // No limit → the whole conversation, oldest-first.
      expect((await storage.loadMessages(c)).map((m) => m.body), [
        'p0',
        'p1',
        'p2',
        'p3',
        'p4',
        'p5',
        'p6',
        'p7',
        'p8',
        'p9',
      ]);
      // limit < count → the LATEST `limit`, still oldest-first within the window.
      expect((await storage.loadMessages(c, limit: 3)).map((m) => m.body), [
        'p7',
        'p8',
        'p9',
      ]);
      // limit >= count → the whole conversation (no truncation).
      expect((await storage.loadMessages(c, limit: 100)).length, 10);
      // A grown window ("load earlier") reveals older messages from the tail.
      expect(
        (await storage.loadMessages(c, limit: 6)).map((m) => m.body).first,
        'p4',
      );
    },
  );

  test(
    'same-timestamp messages sort deterministically by id (cross-device-stable)',
    () async {
      final c = _id(4).hex;
      final ts = DateTime(2026, 7, 1, 12);
      // Append OUT of id order, identical timestamp. id = '<body>-<ms>', so
      // 'aaa-..' < 'zzz-..' — the (timestamp, id) order must be 'aaa' then 'zzz'
      // regardless of insertion/scan order (Dart List.sort is not stable, so a
      // bare-timestamp sort would be arbitrary here).
      await storage.appendMessage(
        _msg(conv: c, dir: MessageDirection.outgoing, body: 'zzz', ts: ts),
      );
      await storage.appendMessage(
        _msg(conv: c, dir: MessageDirection.incoming, body: 'aaa', ts: ts),
      );
      expect((await storage.loadMessages(c)).map((m) => m.body), [
        'aaa',
        'zzz',
      ]);
    },
  );

  test(
    'incremental log fold matches a full scan across appends + status reads',
    () async {
      final a = _id(1).hex; // conversation A (interleaved with B in the log)
      final b = _id(2).hex;
      for (var i = 0; i < 5; i++) {
        await storage.appendMessage(
          _msg(
            conv: i.isEven ? a : b,
            dir: MessageDirection.outgoing,
            body: 'm$i',
            ts: DateTime(2026, 5, 1, 0, i),
          ),
        );
      }
      // Initial fold.
      expect((await storage.loadMessages(a)).map((m) => m.body), [
        'm0',
        'm2',
        'm4',
      ]);
      // A status flip + a new append → exercised as INCREMENTAL folds (the read
      // above already advanced the watermark).
      final m0Id = (await storage.loadMessages(a)).first.id;
      await storage.markMessageStatus(a, m0Id, MessageStatus.delivered);
      await storage.appendMessage(
        _msg(
          conv: a,
          dir: MessageDirection.outgoing,
          body: 'm5',
          ts: DateTime(2026, 5, 1, 0, 5),
        ),
      );
      final after = await storage.loadMessages(a);
      expect(after.map((m) => m.body), ['m0', 'm2', 'm4', 'm5']);
      expect(
        after.firstWhere((m) => m.body == 'm0').status,
        MessageStatus.delivered,
      );
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
    },
  );

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
    await storage.appendMessage(
      _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'first',
        ts: DateTime(2026, 1, 1, 10),
      ),
    );
    await storage.appendMessage(
      _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'second',
        ts: DateTime(2026, 1, 1, 11),
      ),
    );

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

    await storage.appendMessage(
      _msg(
        conv: a,
        dir: MessageDirection.outgoing,
        body: 'hi a',
        ts: DateTime(2026, 1, 1, 9),
      ),
    );
    await storage.appendMessage(
      _msg(
        conv: b,
        dir: MessageDirection.outgoing,
        body: 'hi b',
        ts: DateTime(2026, 1, 1, 12),
      ),
    );

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
    await storage.appendMessage(
      _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'one',
        ts: DateTime(2026, 5, 1, 10),
      ),
    );
    await storage.appendMessage(
      _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'two',
        ts: DateTime(2026, 5, 1, 11),
      ),
    );
    // Our own outgoing message never counts as unread.
    await storage.appendMessage(
      _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'mine',
        ts: DateTime(2026, 5, 1, 12),
      ),
    );

    expect(
      (await storage.loadConversations())
          .firstWhere((c) => c.id == conv)
          .unread,
      2,
    );

    // Opening it marks read up to the latest message.
    await storage.markRead(conv);
    expect(
      (await storage.loadConversations())
          .firstWhere((c) => c.id == conv)
          .unread,
      0,
    );

    // A newer incoming bumps unread again.
    await storage.appendMessage(
      _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'three',
        ts: DateTime(2026, 5, 1, 13),
      ),
    );
    expect(
      (await storage.loadConversations())
          .firstWhere((c) => c.id == conv)
          .unread,
      1,
    );
  });

  test(
    'loadRoster is null for a plain identity space (the discriminator)',
    () async {
      expect(await storage.loadRoster(), isNull);
    },
  );

  test(
    'roster round-trips: labels + opaque SpaceKeys, survives reopen',
    () async {
      final entries = [
        RosterEntry(
          label: 'me',
          spaceKeys: Uint8List.fromList(List.filled(64, 1)),
        ),
        RosterEntry(
          label: 'relatives',
          spaceKeys: Uint8List.fromList(List.filled(64, 2)),
          anonymous: true,
        ),
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
      expect((await reopened.loadRoster())!.map((e) => e.label), [
        'me',
        'relatives',
      ]);
    },
  );

  test('a messaged contact sorts above a message-less one', () async {
    await storage.upsertContact(Contact(nodeId: _id(5), name: 'Carol'));
    await storage.appendMessage(
      _msg(
        conv: _id(6).hex,
        dir: MessageDirection.outgoing,
        body: 'yo',
        ts: DateTime(2026, 2, 1),
      ),
    );

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
      ts: DateTime(2026, 3, 1),
    );
    await storage.appendMessage(m);

    await storage.editMessage(conv, m.id, 'corrected');

    final msgs = await storage.loadMessages(conv);
    expect(msgs.length, 1); // no duplicate row — last-write-wins by log_id
    expect(msgs.single.body, 'corrected');
    expect(msgs.single.edited, isTrue);
    // The prior text no longer reads back anywhere in the log.
    expect(msgs.any((x) => x.body == 'origial'), isFalse);
  });

  test(
    'deleteMessage removes it entirely (incl. a received message)',
    () async {
      final conv = _id(8).hex;
      final incoming = _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'received secret',
        ts: DateTime(2026, 3, 2),
      );
      final mine = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'keep me',
        ts: DateTime(2026, 3, 3),
      );
      await storage.appendMessage(incoming);
      await storage.appendMessage(mine);

      await storage.deleteMessage(conv, incoming.id);

      final msgs = await storage.loadMessages(conv);
      expect(msgs.map((m) => m.body), ['keep me']);
      expect(msgs.any((m) => m.body == 'received secret'), isFalse);
    },
  );

  test('edit/delete on an unknown id is a no-op', () async {
    await storage.editMessage(_id(9).hex, 'nope', 'x');
    await storage.deleteMessage(_id(9).hex, 'nope');
    expect(await storage.loadMessages(_id(9).hex), isEmpty);
  });

  test('deleting a file message also purges the stored blob', () async {
    final conv = _id(11).hex;
    await storage.storeFile(
      'blob1',
      Uint8List.fromList([1, 2, 3, 4]),
      name: 'secret.bin',
    );
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
      ts: DateTime(2026, 4, 1),
    );
    await storage.appendMessage(m);
    await storage.markMessageStatus(conv, m.id, MessageStatus.delivered);

    await storage.editMessage(conv, m.id, 'v2');

    final msg = (await storage.loadMessages(conv)).single;
    expect(msg.body, 'v2');
    expect(msg.edited, isTrue);
    expect(
      msg.status,
      MessageStatus.delivered,
      reason: 'an edit must not reset delivery state',
    );
  });

  test(
    'a status update after an edit still folds onto the edited message',
    () async {
      final conv = _id(13).hex;
      final m = _msg(
        conv: conv,
        dir: MessageDirection.outgoing,
        body: 'hello',
        ts: DateTime(2026, 4, 2),
      );
      await storage.appendMessage(m);
      await storage.editMessage(conv, m.id, 'hello (fixed)');
      await storage.markMessageStatus(conv, m.id, MessageStatus.delivered);

      final msg = (await storage.loadMessages(conv)).single;
      expect(msg.body, 'hello (fixed)');
      expect(msg.edited, isTrue);
      expect(msg.status, MessageStatus.delivered);
    },
  );

  test('a fold-warming lookup (isMessageDeleted) does not stale-cache '
      'loadMessages (scan-throughput cache invariant)', () async {
    final conv = _id(33).hex;
    // isMessageDeleted / a dedup check runs the shared incremental fold; a later
    // loadMessages must observe the SAME up-to-date state, not a stale list cached
    // before the message was folded in.
    expect(
      await storage.isMessageDeleted(conv, 'x'),
      isFalse,
    ); // warms an empty fold
    expect(await storage.loadMessages(conv), isEmpty);
    await storage.appendMessage(
      _msg(
        conv: conv,
        dir: MessageDirection.incoming,
        body: 'arrived',
        ts: DateTime(2026, 7, 1),
      ),
    );
    // Warm the fold via the lookup FIRST (advances the fold watermark)...
    expect(await storage.isMessageDeleted(conv, 'x'), isFalse);
    // ...then loadMessages must still see the new message (not a stale cache).
    expect((await storage.loadMessages(conv)).map((m) => m.body), ['arrived']);
  });

  test('two conversations with the SAME message id both survive the scan '
      '(MSGID-GLOBAL scan-collision)', () async {
    final convA = _id(40).hex;
    final convB = _id(41).hex;
    // A hostile peer in B reuses an id that also names a message in A. Keying the
    // scan by the bare id would let B's message overwrite A's in the fold.
    await storage.appendMessage(
      Message(
        id: 'dup',
        conversationId: convA,
        direction: MessageDirection.incoming,
        body: 'A original',
        timestamp: DateTime(2026, 6, 1),
      ),
    );
    await storage.appendMessage(
      Message(
        id: 'dup',
        conversationId: convB,
        direction: MessageDirection.incoming,
        body: 'B impostor',
        timestamp: DateTime(2026, 6, 2),
      ),
    );

    final inA = await storage.loadMessages(convA);
    final inB = await storage.loadMessages(convB);
    expect(
      inA.map((m) => m.body),
      ['A original'],
      reason: "A's message must not be erased by B's same-id message",
    );
    expect(inB.map((m) => m.body), ['B impostor']);

    // Deleting B's copy leaves A's intact (delete is conversation-scoped).
    await storage.deleteMessage(convB, 'dup');
    expect((await storage.loadMessages(convA)).map((m) => m.body), [
      'A original',
    ]);
    expect(await storage.loadMessages(convB), isEmpty);
  });

  test('a status op is conversation-scoped: a foreign conversation cannot flip '
      'another chat\'s message status', () async {
    final convA = _id(30).hex;
    final convB = _id(31).hex;
    final m = Message(
      id: 'shared-status-id',
      conversationId: convA,
      direction: MessageDirection.outgoing,
      body: 'to A',
      timestamp: DateTime(2026, 5, 2),
      status: MessageStatus.sent,
    );
    await storage.appendMessage(m);
    // An attacker in conversation B names A's id. The op must NOT apply.
    await storage.markMessageStatus(
      convB,
      'shared-status-id',
      MessageStatus.delivered,
    );
    expect(
      (await storage.loadMessages(convA)).single.status,
      MessageStatus.sent,
      reason: 'a status from another conversation must not apply',
    );
    // The owning conversation CAN flip it.
    await storage.markMessageStatus(
      convA,
      'shared-status-id',
      MessageStatus.delivered,
    );
    expect(
      (await storage.loadMessages(convA)).single.status,
      MessageStatus.delivered,
    );
  });

  test('deleting the same message twice is idempotent', () async {
    final conv = _id(14).hex;
    final m = _msg(
      conv: conv,
      dir: MessageDirection.incoming,
      body: 'gone',
      ts: DateTime(2026, 4, 3),
    );
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
      ts: DateTime(2026, 4, 4),
    );
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
      ts: DateTime(2026, 3, 4),
    );
    await storage.appendMessage(m);
    await storage.deleteMessage(conv, m.id);
    await storage.scrubDeleted(); // reclaim orphaned chunks

    expect(await storage.loadMessages(conv), isEmpty);
  });

  test('edit/delete are conversation-scoped: naming a foreign conversation '
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
    expect(
      await storage.isMessageDeleted(convB, 'shared-id'),
      isFalse,
      reason: 'B must not see A\'s message as deleted',
    );

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
