import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/relay_key_cache.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';

/// Counts commits so tests can assert a re-write of unchanged data is a NO-OP.
/// Every real commit permanently grows the append-only container by a padded
/// bucket — the invariant under test is "no change ⇒ no commit".
class _CountingStore implements KvLogStore {
  _CountingStore(this._inner);
  final FakeKvLogStore _inner;
  int commits = 0;

  @override
  int commit(List<KvLogOp> ops) {
    if (ops.isNotEmpty) commits++;
    return _inner.commit(ops);
  }

  @override
  Uint8List? get(int namespace, Uint8List key) => _inner.get(namespace, key);
  @override
  List<Uint8List> kvKeys(int namespace) => _inner.kvKeys(namespace);
  @override
  Uint8List? readLog(int namespace, int logId) =>
      _inner.readLog(namespace, logId);
  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _inner.iterLogRange(
    namespace: namespace,
    start: start,
    end: end,
    limit: limit,
  );
  @override
  int count(int namespace) => _inner.count(namespace);
  @override
  int eraseNamespace(int namespace) => _inner.eraseNamespace(namespace);
  @override
  void scrub() => _inner.scrub();
  @override
  Uint8List exportKeys() => _inner.exportKeys();
  @override
  void close() => _inner.close();
}

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late _CountingStore counting;
  late HiddenVolumeStorage storage;

  setUp(() async {
    counting = _CountingStore(FakeKvLogStore());
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => counting,
    );
    await storage.open(password: 'pw', createIfMissing: true);
  });

  group('putSetting', () {
    test('re-putting an identical value does not commit', () async {
      await storage.putSetting('k', 'value-1');
      final after = counting.commits;
      for (var i = 0; i < 5; i++) {
        await storage.putSetting('k', 'value-1');
      }
      expect(counting.commits, after, reason: 'no-op re-puts must not commit');
      expect(await storage.getSetting('k'), 'value-1');
    });

    test('a changed value still commits and reads back', () async {
      await storage.putSetting('k', 'value-1');
      final after = counting.commits;
      await storage.putSetting('k', 'value-2');
      expect(counting.commits, after + 1);
      expect(await storage.getSetting('k'), 'value-2');
    });
  });

  group('saveNodeConfig', () {
    test('re-saving an identical config does not commit', () async {
      await storage.saveNodeConfig('[identity]\nkey="a"');
      final after = counting.commits;
      await storage.saveNodeConfig('[identity]\nkey="a"');
      expect(counting.commits, after);
      await storage.saveNodeConfig('[identity]\nkey="b"');
      expect(counting.commits, after + 1);
      expect(await storage.loadNodeConfig(), '[identity]\nkey="b"');
    });
  });

  group('hot metadata writes', () {
    test('re-saving an identical identity does not commit', () async {
      final identity = Identity(
        nodeId: NodeId(_bytes(32, 11)),
        displayName: 'Me',
      );
      await storage.saveIdentity(identity);
      final after = counting.commits;
      await storage.saveIdentity(identity);
      expect(counting.commits, after);

      await storage.saveIdentity(
        Identity(nodeId: identity.nodeId, displayName: 'Other'),
      );
      expect(counting.commits, after + 1);
      expect((await storage.loadIdentity())!.displayName, 'Other');
    });

    test('re-saving an identical roster does not commit', () async {
      final entries = [RosterEntry(label: 'main', spaceKeys: _bytes(64, 12))];
      await storage.saveRoster(entries);
      final after = counting.commits;
      await storage.saveRoster(entries);
      expect(counting.commits, after);

      await storage.saveRoster([
        ...entries,
        RosterEntry(label: 'work', spaceKeys: _bytes(64, 13)),
      ]);
      expect(counting.commits, after + 1);
      expect((await storage.loadRoster())!.map((e) => e.label), [
        'main',
        'work',
      ]);
    });

    test('re-upserting an identical contact does not commit', () async {
      final contact = Contact(nodeId: NodeId(_bytes(32, 14)), name: 'Ada');
      await storage.upsertContact(contact);
      final after = counting.commits;
      await storage.upsertContact(contact);
      expect(counting.commits, after);

      await storage.upsertContact(
        Contact(nodeId: contact.nodeId, name: 'Ada Lovelace'),
      );
      expect(counting.commits, after + 1);
      expect((await storage.getContact(contact.nodeId))!.name, 'Ada Lovelace');
    });

    test('markRead is a no-op when the marker is already current', () async {
      final conv = NodeId(_bytes(32, 15)).hex;
      await storage.appendMessage(
        Message(
          id: 'm1',
          conversationId: conv,
          direction: MessageDirection.incoming,
          body: 'one',
          timestamp: DateTime(2026, 7, 9, 10),
        ),
      );
      await storage.markRead(conv);
      final after = counting.commits;
      await storage.markRead(conv);
      expect(counting.commits, after);

      await storage.appendMessage(
        Message(
          id: 'm2',
          conversationId: conv,
          direction: MessageDirection.incoming,
          body: 'two',
          timestamp: DateTime(2026, 7, 9, 11),
        ),
      );
      await storage.markRead(conv);
      expect(
        counting.commits,
        after + 2,
        reason: 'one append commit plus one newer read-marker commit',
      );
    });
  });

  group('FileStore.storeFile', () {
    test('re-storing identical bytes is a no-op (sync twin)', () {
      final s = _CountingStore(FakeKvLogStore());
      final fs = FileStore(s);
      final data = _bytes(20000, 1);
      fs.storeFile('id', data, name: 'a.bin');
      final after = s.commits;
      fs.storeFile('id', data, name: 'a.bin');
      expect(s.commits, after, reason: 'identical re-store must not commit');
      expect(fs.loadFile('id'), data);
    });

    test('replacing with different bytes purges the old chunks first (sync)', () {
      final s = _CountingStore(FakeKvLogStore());
      final fs = FileStore(s);
      final v1 = _bytes(20000, 2);
      final v2 = _bytes(15000, 3);
      fs.storeFile('id', v1);
      // Old layout: chunks at base..base+count-1.
      final metaRaw = s.get(
        Ns.settings,
        Uint8List.fromList('file:id'.codeUnits),
      );
      expect(metaRaw, isNotNull);
      fs.storeFile('id', v2);
      expect(fs.loadFile('id'), v2);
      // The v1 chunk records must have been scrubbed (zero-length payloads), not
      // left as live-but-unreachable log records.
      final firstOldChunk = s.readLog(Ns.fileChunks, 1);
      expect(firstOldChunk, isNotNull);
      expect(
        firstOldChunk,
        isEmpty,
        reason: 'replaced blob chunks must be zeroed, not leaked',
      );
    });

    test(
      're-storing identical bytes is a no-op (storage async path)',
      () async {
        final data = _bytes(20000, 4);
        await storage.storeFile('mf:x', data, name: 'manifest');
        final after = counting.commits;
        await storage.storeFile('mf:x', data, name: 'manifest');
        expect(counting.commits, after);
        expect(await storage.loadFile('mf:x'), data);
      },
    );

    test(
      'replacing with different bytes still works (storage async path)',
      () async {
        final v1 = _bytes(9000, 5);
        final v2 = _bytes(9100, 6);
        await storage.storeFile('mf:y', v1);
        await storage.storeFile('mf:y', v2);
        expect(await storage.loadFile('mf:y'), v2);
      },
    );
  });

  group('markMessageStatus', () {
    test(
      're-marking the stored status does not commit (per-launch re-acks)',
      () async {
        final msg = await storage.appendMessage(
          Message(
            id: 'm1',
            conversationId: 'conv',
            direction: MessageDirection.outgoing,
            body: 'hi',
            timestamp: DateTime(2026, 7, 1),
          ),
        );
        await storage.markMessageStatus(
          'conv',
          msg.id,
          MessageStatus.delivered,
        );
        final after = counting.commits;
        // The peer re-acks once per launch while its relay blob lives; the
        // stored fold already says delivered — must be a true no-op.
        for (var i = 0; i < 3; i++) {
          await storage.markMessageStatus(
            'conv',
            msg.id,
            MessageStatus.delivered,
          );
        }
        expect(counting.commits, after);
        // A genuinely different status still lands.
        await storage.markMessageStatus('conv', msg.id, MessageStatus.failed);
        expect(counting.commits, after + 1);
        final loaded = await storage.loadMessages('conv');
        expect(loaded.single.status, MessageStatus.failed);
      },
    );
  });

  group('StorageRelayKeyCache across launches', () {
    test(
      'a fresh cache instance does not re-commit a stored fresh key',
      () async {
        final relay = NodeId(Uint8List.fromList(List.filled(32, 7)));
        final key = Uint8List.fromList(List.generate(32, (i) => i));
        final first = StorageRelayKeyCache(storage);
        await first.put(relay, key);
        final after = counting.commits;

        // Simulate an app relaunch: a NEW cache instance (empty in-RAM shadow)
        // over the same storage re-resolves the same relay key.
        final second = StorageRelayKeyCache(storage);
        await second.put(relay, key);
        expect(
          counting.commits,
          after,
          reason:
              're-put of a stored fresh key on a new launch must not '
              'commit (the old code re-wrote it with a fresh expiry)',
        );
        expect(await second.get(relay), key);

        // A genuinely different key still persists.
        final other = Uint8List.fromList(List.generate(32, (i) => 255 - i));
        await second.put(relay, other);
        expect(counting.commits, after + 1);
        expect(await second.get(relay), other);
      },
    );

    test(
      'a fresh cache instance does not re-commit the same preferred relay',
      () async {
        final relay = NodeId(Uint8List.fromList(List.filled(32, 9)));
        final first = StorageRelayKeyCache(storage);
        await first.setPreferredRelay(relay);
        final after = counting.commits;
        final second = StorageRelayKeyCache(storage);
        await second.setPreferredRelay(relay);
        expect(counting.commits, after);
        expect((await second.getPreferredRelay())!.hex, relay.hex);
      },
    );
  });
}
