import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/contact_decision_sync.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
Uint8List key(String s) => Uint8List.fromList(utf8.encode(s));

class _Store extends FakeKvLogStore {
  String? fault;
  @override
  int commit(List<KvLogOp> ops) {
    final decision = ops.whereType<PutOp>().any(
      (op) =>
          op.namespace == Ns.settings &&
          utf8.decode(op.key).startsWith('contact.status.pending.v1:'),
    );
    final ack = ops.whereType<DeleteOp>().any(
      (op) =>
          op.namespace == Ns.settings &&
          utf8.decode(op.key).startsWith('contact.status.pending.v1:'),
    );
    if (fault == 'decision-before' && decision ||
        fault == 'ack-before' && ack) {
      fault = null;
      throw StateError('PRIVATE_CONTACT_LEDGER_CANARY before commit');
    }
    final result = super.commit(ops);
    if (fault == 'decision-after' && decision || fault == 'ack-after' && ack) {
      fault = null;
      throw StateError('PRIVATE_CONTACT_LEDGER_CANARY reply loss');
    }
    return result;
  }
}

Future<HiddenVolumeStorage> open(FakeKvLogStore kv) async {
  final s = HiddenVolumeStorage(
    ({required password, required bool create}) => kv,
  );
  expect(await s.open(password: 'fixture', createIfMissing: true), true);
  addTearDown(s.close);
  return s;
}

void main() {
  test(
    'local decisions are monotonic, CAS-acked and cannot be undone by delayed mirrors',
    () async {
      final kv = _Store(), peer = id(2);
      var s = await open(kv);
      await s.upsertContact(Contact(nodeId: peer, name: 'kept', pinned: true));
      await s.setContactStatus(peer, ContactStatus.accepted);
      final first = (await s.pendingContactDecisions()).single;
      await s.setContactStatus(peer, ContactStatus.blocked);
      final block = (await s.pendingContactDecisions()).single;
      expect(block.atMs, greaterThan(first.atMs));
      expect(await s.acknowledgeContactDecision(first), false);
      expect(await s.acknowledgeContactDecision(block), true);
      await s.close();
      s = await open(kv);
      expect(
        await s.applyContactDecision(peer, ContactStatus.accepted, first.atMs),
        false,
      );
      expect((await s.getContact(peer))?.status, ContactStatus.blocked);
      await s.setContactStatus(peer, ContactStatus.accepted);
      final next = (await s.pendingContactDecisions()).single;
      expect(next.atMs, greaterThan(block.atMs));
      expect((await s.getContact(peer))?.name, 'kept');
      expect((await s.getContact(peer))?.pinned, true);
      expect(
        await s.applyContactDecision(peer, ContactStatus.blocked, next.atMs),
        true,
      );
      final winner = DeviceSyncEvent(
        kind: DeviceSyncKind.contactUp,
        key: 's:${peer.hex}',
        tsMs: next.atMs,
        payload: {'status': 'blocked'},
      );
      expect(isNewerDeviceSync(winner, contactDecisionEvent(next)), true);
      await s.acknowledgeContactDecision(next);
      expect(
        await s.pendingContactDecisions(),
        isEmpty,
        reason: 'mirrors do not echo',
      );
      await s.setContactStatus(peer, ContactStatus.accepted);
      expect(
        (await s.pendingContactDecisions()).single.atMs,
        greaterThan(winner.tsMs),
      );
    },
  );
  for (final mode in ['decision-before', 'decision-after']) {
    test('local status and intent share the transaction: $mode', () async {
      final kv = _Store();
      final s = await open(kv);
      final peer = id(2);
      await s.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.pendingIncoming),
      );
      kv.fault = mode;
      await expectLater(
        s.setContactStatus(peer, ContactStatus.blocked),
        throwsStateError,
      );
      expect(
        (await s.getContact(peer))?.status,
        mode == 'decision-before'
            ? ContactStatus.pendingIncoming
            : ContactStatus.blocked,
      );
      expect(
        (await s.pendingContactDecisions()).length,
        mode == 'decision-before' ? 0 : 1,
      );
      await s.close();
      final cold = await open(kv);
      expect(
        (await cold.pendingContactDecisions()).length,
        mode == 'decision-before' ? 0 : 1,
      );
    });
  }
  test(
    'unlinked device retains intent; a linked retry posts its original time',
    () async {
      final s = await open(_Store());
      final peer = id(2);
      await s.setContactStatus(peer, ContactStatus.accepted);
      final record = (await s.pendingContactDecisions()).single;
      var linked = false;
      var attempts = 0;
      final posted = <DeviceSyncEvent>[];
      final errors = ErrorJournal();
      final p = ContactDecisionPublisher(
        storage: s,
        isLinked: () async => linked,
        isOwnDevice: (_) async => false,
        loadPublished: () async => const [],
        journal: errors,
        post: (events) async {
          attempts++;
          posted.addAll(events);
          if (attempts == 1) {
            throw const FormatException(
              'PRIVATE_CONTACT_LEDGER_CANARY',
              'PRIVATE_CONTACT_LEDGER_CANARY',
            );
          }
          return List.filled(events.length, attempts > 2);
        },
      );
      addTearDown(p.close);
      expect(await p.flush(), false);
      expect(posted, isEmpty);
      expect(errors.entries, isEmpty);
      linked = true;
      expect(await p.flush(), false);
      expect(await s.pendingContactDecisions(), hasLength(1));
      expect(await p.flush(), false);
      expect(await s.pendingContactDecisions(), hasLength(1));
      expect(await p.flush(), true);
      expect(await s.pendingContactDecisions(), isEmpty);
      expect(posted.map((e) => e.toBody()).toSet(), {
        contactDecisionEvent(record).toBody(),
      });
      expect(errors.entries.single.kind, 'contact-status-sync');
      expect(
        errors.entries.single.message,
        isNot(contains('PRIVATE_CONTACT_LEDGER_CANARY')),
      );
      expect(
        jsonEncode(errors.entries.single.toJson()),
        isNot(contains('PRIVATE_CONTACT_LEDGER_CANARY')),
      );
    },
  );
  for (final mode in ['ack-before', 'ack-after']) {
    test('committed publication is not duplicated after $mode', () async {
      final kv = _Store();
      var s = await open(kv);
      final peer = id(2);
      await s.setContactStatus(peer, ContactStatus.blocked);
      final published = <String, DeviceSyncEvent>{};
      var posts = 0;
      ContactDecisionPublisher publisher(HiddenVolumeStorage storage) =>
          ContactDecisionPublisher(
            storage: storage,
            isLinked: () async => true,
            isOwnDevice: (_) async => false,
            loadPublished: () async => published.values.toList(),
            post: (events) async {
              posts++;
              for (final e in events) {
                published[e.key.substring(2)] = e;
              }
              return List.filled(events.length, true);
            },
            journal: ErrorJournal(),
          );
      var p = publisher(s);
      kv.fault = mode;
      expect(await p.flush(), false);
      await p.close();
      await s.close();
      s = await open(kv);
      p = publisher(s);
      addTearDown(p.close);
      expect(await p.flush(), true);
      expect(posts, 1);
      expect(await s.pendingContactDecisions(), isEmpty);
    });
  }
  test(
    'a newer committed block suppresses an old pending acceptance without restamping',
    () async {
      final s = await open(_Store());
      final peer = id(2);
      await s.setContactStatus(peer, ContactStatus.accepted);
      final old = (await s.pendingContactDecisions()).single;
      final winner = DeviceSyncEvent(
        kind: DeviceSyncKind.contactUp,
        key: 's:${peer.hex}',
        tsMs: old.atMs + 10,
        payload: {'status': 'blocked'},
      );
      await s.applyContactDecision(peer, ContactStatus.blocked, winner.tsMs);
      final p = ContactDecisionPublisher(
        storage: s,
        isLinked: () async => true,
        isOwnDevice: (_) async => false,
        loadPublished: () async => [winner],
        post: (_) async =>
            throw StateError('must not post obsolete acceptance'),
      );
      addTearDown(p.close);
      expect(await p.flush(), true);
      expect(await s.pendingContactDecisions(), isEmpty);
      expect((await s.getContact(peer))?.status, ContactStatus.blocked);
    },
  );
  for (final identical in [false, true]) {
    test(
      'future committed decision suppresses only an exact duplicate identical=$identical',
      () async {
        final s = await open(_Store());
        final peer = id(2);
        if (identical) {
          await s.applyContactDecision(
            peer,
            ContactStatus.blocked,
            DateTime.now().millisecondsSinceEpoch + 10000000,
          );
        }
        await s.setContactStatus(peer, ContactStatus.accepted);
        final record = (await s.pendingContactDecisions()).single;
        final event = contactDecisionEvent(record);
        final old = identical
            ? event
            : DeviceSyncEvent(
                kind: event.kind,
                key: event.key,
                tsMs: event.tsMs + 10000000,
                payload: const {'status': 'blocked'},
              );
        var posts = 0;
        final p = ContactDecisionPublisher(
          storage: s,
          isLinked: () async => true,
          isOwnDevice: (_) async => false,
          loadPublished: () async => [old],
          post: (events) async {
            posts++;
            return List.filled(events.length, true);
          },
        );
        addTearDown(p.close);
        expect(await p.flush(), true);
        expect(
          posts,
          identical ? 0 : 1,
          reason:
              'an ineffective future block must not hide today’s acceptance',
        );
        expect(await s.pendingContactDecisions(), isEmpty);
      },
    );
  }

  test(
    'a decision committed during publication survives an old CAS ack',
    () async {
      final s = await open(_Store());
      final peer = id(2);
      await s.setContactStatus(peer, ContactStatus.accepted);
      final entered = Completer<void>(), release = Completer<void>();
      final sent = <DeviceSyncEvent>[];
      final p = ContactDecisionPublisher(
        storage: s,
        isLinked: () async => true,
        isOwnDevice: (_) async => false,
        loadPublished: () async => const [],
        post: (events) async {
          sent.addAll(events);
          if (sent.length == 1) {
            entered.complete();
            await release.future;
          }
          return List.filled(events.length, true);
        },
      );
      addTearDown(p.close);
      final work = p.flush();
      await entered.future;
      await s.setContactStatus(peer, ContactStatus.blocked);
      release.complete();
      expect(await work, true);
      expect(sent.map((e) => e.payload['status']), ['accepted', 'blocked']);
      expect(sent[1].tsMs, greaterThan(sent[0].tsMs));
      expect(await s.pendingContactDecisions(), isEmpty);
    },
  );
  test(
    'close joins an active post, leaves its intent, and admits no new work',
    () async {
      final s = await open(_Store());
      final peer = id(2);
      await s.setContactStatus(peer, ContactStatus.accepted);
      final entered = Completer<void>(), release = Completer<void>();
      var closed = false;
      final p = ContactDecisionPublisher(
        storage: s,
        isLinked: () async => true,
        isOwnDevice: (_) async => false,
        loadPublished: () async => const [],
        post: (events) async {
          entered.complete();
          await release.future;
          return [true];
        },
      );
      final work = p.flush();
      await entered.future;
      final closing = p.close().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, false);
      release.complete();
      expect(await work, false);
      await closing;
      expect(await s.pendingContactDecisions(), hasLength(1));
      expect(await p.flush(), false);
    },
  );
  test(
    'own-device contacts are excluded and a shadowed exact event is not posted again',
    () async {
      final s = await open(_Store());
      await s.setContactStatus(id(1), ContactStatus.accepted);
      await s.setContactStatus(id(2), ContactStatus.accepted);
      final records = await s.pendingContactDecisions();
      final exact = contactDecisionEvent(
        records.singleWhere((r) => r.peer == id(2)),
      );
      final future = DeviceSyncEvent(
        kind: exact.kind,
        key: exact.key,
        tsMs: exact.tsMs + 10000000,
        payload: const {'status': 'blocked'},
      );
      final p = ContactDecisionPublisher(
        storage: s,
        isLinked: () async => true,
        isOwnDevice: (peer) async => peer == id(1),
        loadPublished: () async => [exact, future],
        post: (_) async =>
            throw StateError('must not post duplicate or own contact'),
      );
      addTearDown(p.close);
      expect(await p.flush(), true);
      expect(await s.pendingContactDecisions(), isEmpty);
    },
  );

  test(
    'bounded pages progress past a refused peer; retries retain the original event',
    () async {
      final s = await open(_Store());
      for (var n = 1; n <= 130; n++) {
        await s.setContactStatus(id(n), ContactStatus.accepted);
      }
      var first = true;
      final batches = <int>[];
      final sent = <DeviceSyncEvent>[];
      final p = ContactDecisionPublisher(
        storage: s,
        isLinked: () async => true,
        isOwnDevice: (_) async => false,
        loadPublished: () async => const [],
        post: (events) async {
          batches.add(events.length);
          sent.addAll(events);
          return [
            for (final e in events) !(first && e.key == 's:${id(1).hex}'),
          ];
        },
      );
      addTearDown(p.close);
      expect(await p.flush(), false);
      expect(batches, [64, 64, 2]);
      expect(await s.pendingContactDecisions(), hasLength(1));
      first = false;
      expect(await p.flush(), true);
      expect(await s.pendingContactDecisions(), isEmpty);
      expect(sent.first.toBody(), sent.last.toBody());
    },
  );
  test(
    'corrupt obligations remain; removing or erasing the contact removes pending plaintext',
    () async {
      final kv = _Store();
      final s = await open(kv);
      final peer = id(2);
      await s.setContactStatus(peer, ContactStatus.blocked);
      final pendingKey = key('contact.status.pending.v1:${peer.hex}');
      kv.commit([
        PutOp(Ns.settings, pendingKey, key('{PRIVATE_CONTACT_LEDGER_CANARY')),
      ]);
      await expectLater(s.pendingContactDecisions(), throwsStateError);
      expect(kv.get(Ns.settings, pendingKey), isNotNull);
      await s.removeConversation(peer);
      expect(kv.get(Ns.settings, pendingKey), isNull);
      expect(await s.pendingContactDecisions(), isEmpty);
      await s.setContactStatus(peer, ContactStatus.accepted);
      await s.eraseSpace();
      expect(await s.pendingContactDecisions(), isEmpty);
    },
  );
}
