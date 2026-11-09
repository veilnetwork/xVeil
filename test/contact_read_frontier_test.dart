import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

class _Store extends SyncWrappedAsyncKvLogStore
    implements AsyncKvRequestFrontier {
  _Store(this.raw) : super(raw);
  final FakeKvLogStore raw;
  int serial = 0, contactReads = 0;
  bool hold = false, enabled = true, failNext = false, extraCommand = false;
  final pending =
      <({Completer<Uint8List?> reply, Uint8List? value, bool fail})>[];
  @override
  int? get requestFrontier => enabled ? serial : null;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) {
    serial++;
    if (namespace != Ns.contacts) return super.get(namespace, key);
    contactReads++;
    final value = raw.get(namespace, key);
    if (extraCommand) unawaited(commit([]));
    if (!hold) return Future.value(value);
    final reply = Completer<Uint8List?>();
    pending.add((reply: reply, value: value, fail: failNext));
    failNext = false;
    return reply.future;
  }

  @override
  Future<int> commit(List<KvLogOp> ops) {
    serial++;
    return super.commit(ops);
  }

  @override
  Future<void> close() {
    serial++;
    return super.close();
  }

  void release() {
    final replies = List.of(pending);
    pending.clear();
    for (final request in replies) {
      if (request.fail) {
        request.reply.completeError(StateError('fixture read failure'));
      } else {
        request.reply.complete(request.value);
      }
    }
  }
}

void main() {
  final peer = NodeId(Uint8List(32)..fillRange(0, 32, 7));
  final other = NodeId(Uint8List(32)..fillRange(0, 32, 8));
  late _Store store;
  late HiddenVolumeStorage storage;
  setUp(() async {
    store = _Store(FakeKvLogStore());
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => store,
    );
    await storage.open(password: 'fixture');
    await storage.upsertContact(Contact(nodeId: peer, name: 'original'));
    await storage.upsertContact(Contact(nodeId: other, name: 'other'));
    store.contactReads = 0;
    store.hold = true;
  });
  tearDown(() async {
    store.release();
    await storage.close();
  });

  test('concurrent contact reads share only one queued observation', () async {
    final reads = [for (var i = 0; i < 32; i++) storage.getContact(peer)];
    try {
      expect(store.contactReads, 1);
    } finally {
      store.release();
      final contacts = await Future.wait(reads);
      expect(contacts.every((c) => c?.name == 'original'), isTrue);
      expect(identical(contacts.first, contacts.last), isFalse);
    }
  });

  test(
    'a queued write separates old and new authorization observations',
    () async {
      final before = storage.getContact(peer);
      final raw =
          jsonDecode(utf8.decode(store.raw.get(Ns.contacts, peer.bytes)!))
              as Map;
      raw['s'] = ContactStatus.blocked.index;
      await store.commit([
        PutOp(
          Ns.contacts,
          peer.bytes,
          Uint8List.fromList(utf8.encode(jsonEncode(raw))),
        ),
      ]);
      final after = storage.getContact(peer);
      store.release();
      expect((await before)?.status, ContactStatus.accepted);
      expect((await after)?.status, ContactStatus.blocked);
      expect(store.contactReads, 2);
    },
  );

  test('any intervening command ends the sharing window', () async {
    final before = storage.getContact(peer);
    await store.get(Ns.settings, Uint8List.fromList([1]));
    final after = storage.getContact(peer);
    expect(store.contactReads, 2);
    store.release();
    await Future.wait([before, after]);
  });

  test('different contacts do not share or reuse an earlier flight', () async {
    final reads = [
      storage.getContact(peer),
      storage.getContact(other),
      storage.getContact(peer),
    ];
    expect(store.contactReads, 3);
    store.release();
    expect((await Future.wait(reads)).map((c) => c?.name), [
      'original',
      'other',
      'original',
    ]);
  });

  test('completed observations are never cached', () async {
    final before = storage.getContact(peer);
    store.release();
    await before;
    final after = storage.getContact(peer);
    expect(store.contactReads, 2);
    store.release();
    await after;
  });

  test(
    'a wrapper dispatching two commands cannot reuse the read witness',
    () async {
      store.extraCommand = true;
      final reads = [storage.getContact(peer), storage.getContact(peer)];
      expect(store.contactReads, 2);
      store.release();
      await Future.wait(reads);
    },
  );

  test(
    'mutable caller IDs cannot change the requested or returned identity',
    () async {
      final mutable = NodeId(peer.bytes);
      final before = storage.getContact(mutable);
      mutable.bytes.setAll(0, other.bytes);
      final after = storage.getContact(mutable);
      expect(store.contactReads, 2);
      store.release();
      expect((await before)?.nodeId, peer);
      expect((await before)?.name, 'original');
      expect((await after)?.nodeId, other);
      expect((await after)?.name, 'other');
    },
  );

  test(
    'old owner completion cannot replace or retire the new owner flight',
    () async {
      final oldStore = store;
      final before = storage.getContact(peer);
      final frontier = oldStore.serial;
      await storage.close();
      store = _Store(FakeKvLogStore());
      await storage.open(password: 'fixture');
      await storage.upsertContact(Contact(nodeId: peer, name: 'new owner'));
      store.serial = frontier; // same numeric witness, different storage owner
      store.contactReads = 0;
      store.hold = true;
      final after = storage.getContact(peer);
      try {
        expect(store.contactReads, 1);
        oldStore.release();
        expect((await before)?.name, 'original');
        final concurrent = storage.getContact(peer);
        expect(store.contactReads, 1);
        store.release();
        expect((await after)?.name, 'new owner');
        expect((await concurrent)?.name, 'new owner');
      } finally {
        oldStore.release();
        store.release();
      }
    },
  );

  test('a store without a queue witness keeps independent reads', () async {
    store.enabled = false;
    final reads = [for (var i = 0; i < 16; i++) storage.getContact(peer)];
    expect(store.contactReads, 16);
    store.release();
    await Future.wait(reads);
  });

  test('failed observations release the flight for a fresh retry', () async {
    store.failNext = true;
    final reads = [
      for (var i = 0; i < 16; i++)
        expectLater(storage.getContact(peer), throwsStateError),
    ];
    try {
      expect(store.contactReads, 1);
    } finally {
      store.release();
      await Future.wait(reads);
    }
    final retry = storage.getContact(peer);
    expect(store.contactReads, 2);
    store.release();
    expect((await retry)?.name, 'original');
  });
}
