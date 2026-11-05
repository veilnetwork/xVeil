import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/contact_preferences_sync.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
Uint8List key(String s) => Uint8List.fromList(utf8.encode(s));

class _Kv extends FakeKvLogStore {
  String? fault;
  @override
  int commit(List<KvLogOp> ops) {
    bool match(Type type) => ops.any(
      (op) => switch (op) {
        PutOp() when type == PutOp =>
          utf8.decode(op.key).startsWith('contact.prefs.pending.v1:'),
        DeleteOp() when type == DeleteOp =>
          utf8.decode(op.key).startsWith('contact.prefs.pending.v1:'),
        _ => false,
      },
    );
    final hit =
        (fault?.startsWith('write') == true && match(PutOp)) ||
        (fault?.startsWith('ack') == true && match(DeleteOp));
    if (hit && fault!.endsWith('before')) {
      fault = null;
      throw StateError('PRIVATE_PREFS_CANARY');
    }
    final result = super.commit(ops);
    if (hit && fault!.endsWith('after')) {
      fault = null;
      throw StateError('PRIVATE_PREFS_CANARY');
    }
    return result;
  }
}

Future<HiddenVolumeStorage> _open(_Kv kv) async {
  final s = HiddenVolumeStorage(
    ({required password, required bool create}) => kv,
  );
  expect(await s.open(password: 'fixture', createIfMissing: true), true);
  addTearDown(s.close);
  await s.upsertContact(Contact(nodeId: id(2), status: ContactStatus.accepted));
  return s;
}

Future<void> edit(HiddenVolumeStorage s, String name, {NodeId? peer}) async =>
    s.updateContactPrefs(
      peer ?? id(2),
      (c) => c.copyWith(name: name),
      queueForSync: true,
    );
ContactPreferencesPublisher pub(
  HiddenVolumeStorage s, {
  Future<List<bool>> Function(List<PendingContactPreferences>)? post,
  Future<List<DeviceSyncEvent>> Function()? load,
  Future<bool> Function()? linked,
  Future<bool> Function(NodeId)? own,
  ErrorJournal? journal,
}) {
  final p = ContactPreferencesPublisher(
    storage: s,
    isLinked: linked ?? () async => true,
    isOwnDevice: own ?? (_) async => false,
    loadPublished: load ?? () async => const [],
    post: post ?? (r) async => List.filled(r.length, true),
    journal: journal,
  );
  addTearDown(p.close);
  return p;
}

void main() {
  for (final existing in ['main', 'policy', 'both']) {
    test(
      'snapshot ACK requires both committed projections existing=$existing',
      () async {
        final s = await _open(_Kv());
        await s.updateContactPrefs(
          id(2),
          (c) => c.copyWith(
            name: 'name',
            disappearingTtlSeconds: 60,
            disappearingSetAtMs: 100,
            disappearingSetBy: id(1).hex,
          ),
          queueForSync: true,
        );
        final record = (await s.pendingContactPreferences()).single;
        final expected = contactPreferencesEvents(record);
        expect(expected, hasLength(2));
        var posts = 0;
        final p = pub(
          s,
          load: () async => existing == 'both'
              ? expected
              : [existing == 'main' ? expected.first : expected.last],
          post: (rows) async {
            posts++;
            return [true];
          },
        );
        expect(await p.flush(), true);
        expect(posts, existing == 'both' ? 0 : 1);
        expect(await s.pendingContactPreferences(), isEmpty);
      },
    );
  }

  for (final mode in ['write-before', 'write-after']) {
    test('preference and snapshot commit atomically $mode', () async {
      final kv = _Kv();
      final store = await _open(kv);
      kv.fault = mode;
      await expectLater(edit(store, 'committed'), throwsStateError);
      expect(
        (await store.getContact(id(2)))!.name,
        mode.endsWith('after') ? 'committed' : null,
      );
      expect(
        await store.pendingContactPreferences(),
        hasLength(mode.endsWith('after') ? 1 : 0),
      );
    });
  }
  test(
    'unlinked and failed handoffs retain original timestamp and safe diagnostics',
    () async {
      final s = await _open(_Kv());
      await edit(s, 'PRIVATE_NAME_CANARY');
      final r = (await s.pendingContactPreferences()).single;
      var linked = false, attempts = 0;
      final bodies = <String>[], errors = ErrorJournal();
      final p = pub(
        s,
        linked: () async => linked,
        journal: errors,
        post: (records) async {
          bodies.addAll(
            records.map((r) => contactPreferencesEvent(r).toBody()),
          );
          attempts++;
          if (attempts == 1) throw StateError('PRIVATE_PREFS_CANARY');
          return List.filled(records.length, attempts > 2);
        },
      );
      expect(await p.flush(), false);
      expect(bodies, isEmpty);
      linked = true;
      expect(await p.flush(), false);
      expect(await s.pendingContactPreferences(), hasLength(1));
      expect(await p.flush(), false);
      expect(await s.pendingContactPreferences(), hasLength(1));
      expect(await p.flush(), true);
      expect(await s.pendingContactPreferences(), isEmpty);
      expect(bodies.toSet(), {contactPreferencesEvent(r).toBody()});
      final exported = jsonEncode(
        errors.entries.map((e) => e.toJson()).toList(),
      );
      expect(exported, isNot(contains('PRIVATE_')));
      expect(errors.entries.single.kind, 'contact-preferences-sync');
    },
  );
  for (final mode in ['ack-before', 'ack-after']) {
    test('committed handoff avoids duplicate post after $mode', () async {
      final kv = _Kv();
      var s = await _open(kv);
      await edit(s, 'one');
      final committed = <DeviceSyncEvent>[];
      var posts = 0;
      ContactPreferencesPublisher make() => pub(
        s,
        load: () async => committed,
        post: (rows) async {
          posts++;
          committed.addAll(rows.expand(contactPreferencesEvents));
          return List.filled(rows.length, true);
        },
      );
      var p = make();
      kv.fault = mode;
      expect(await p.flush(), false);
      await p.close();
      await s.close();
      s = await _open(kv);
      p = make();
      expect(await p.flush(), true);
      expect(posts, 1);
      expect(await s.pendingContactPreferences(), isEmpty);
    });
  }
  test('CAS acknowledgement cannot retire a newer local snapshot', () async {
    final s = await _open(_Kv());
    await edit(s, 'first');
    final posted = <PendingContactPreferences>[];
    final p = pub(
      s,
      post: (rows) async {
        posted.addAll(rows);
        if (posted.length == 1) await edit(s, 'second');
        return List.filled(rows.length, true);
      },
    );
    expect(await p.flush(), true);
    expect(posted.map((r) => r.payload['name']), ['first', 'second']);
    expect(posted.last.atMs, greaterThan(posted.first.atMs));
    expect(await s.pendingContactPreferences(), isEmpty);
  });
  test(
    'only exact committed rows cover a snapshot; own-device prefs are not published',
    () async {
      final s = await _open(_Kv());
      await edit(s, 'one');
      final row = (await s.pendingContactPreferences()).single;
      final old = contactPreferencesEvent(row);
      var posts = 0;
      final p = pub(
        s,
        load: () async => [
          DeviceSyncEvent(
            kind: old.kind,
            key: old.key,
            tsMs: old.tsMs + 10,
            payload: {'name': 'different'},
          ),
        ],
        post: (rows) async {
          posts++;
          return [true];
        },
      );
      expect(await p.flush(), true);
      expect(posts, 1);
      await edit(s, 'two');
      final own = pub(
        s,
        own: (_) async => true,
        post: (_) async => throw StateError('must not publish own contact'),
      );
      expect(await own.flush(), true);
      expect(await s.pendingContactPreferences(), isEmpty);
    },
  );
  test(
    'close joins a pending handoff and preserves retry after admission stops',
    () async {
      final s = await _open(_Kv());
      await edit(s, 'one');
      final entered = Completer<void>(), release = Completer<void>();
      final p = pub(
        s,
        post: (_) async {
          entered.complete();
          await release.future;
          return [true];
        },
      );
      final flush = p.flush();
      await entered.future;
      var closed = false;
      final closing = p.close().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, false);
      release.complete();
      await flush;
      await closing;
      expect(await s.pendingContactPreferences(), hasLength(1));
      expect(await p.flush(), false);
    },
  );
  for (final fault in ['manifest', 'chunk', 'digest']) {
    test(
      'unreadable snapshot is retained and reported safely $fault',
      () async {
        final kv = _Kv(), errors = ErrorJournal();
        final s = await _open(kv);
        await edit(s, 'PRIVATE_NAME_CANARY');
        final peer = id(2).hex;
        kv.commit([
          switch (fault) {
            'manifest' => PutOp(
              Ns.settings,
              key('contact.prefs.pending.v1:$peer'),
              key('PRIVATE_PREFS_CANARY'),
            ),
            'chunk' => DeleteOp(
              Ns.settings,
              key('contact.prefs.data.v1:$peer:0'),
            ),
            _ => PutOp(
              Ns.settings,
              key('contact.prefs.data.v1:$peer:0'),
              key('invalid'),
            ),
          },
        ]);
        expect(await pub(s, journal: errors).flush(), false);
        expect(
          kv.get(Ns.settings, key('contact.prefs.pending.v1:$peer')),
          isNotNull,
        );
        expect(
          jsonEncode(errors.entries.map((e) => e.toJson()).toList()),
          isNot(contains('PRIVATE_')),
        );
        await s.removeConversation(id(2));
        expect(await s.pendingContactPreferences(), isEmpty);
      },
    );
  }
  test(
    'bounded paging drains multiple pages without dropping recipients',
    () async {
      final s = await _open(_Kv());
      for (var i = 2; i <= 132; i++) {
        await s.upsertContact(Contact(nodeId: id(i)));
        await edit(s, 'n$i', peer: id(i));
      }
      final peers = <NodeId>{};
      final p = pub(
        s,
        post: (rows) async {
          expect(rows.length, lessThanOrEqualTo(64));
          peers.addAll(rows.map((r) => r.peer));
          return List.filled(rows.length, true);
        },
      );
      expect(await p.flush(), true);
      expect(peers, hasLength(131));
      expect(await s.pendingContactPreferences(), isEmpty);
    },
  );
}
