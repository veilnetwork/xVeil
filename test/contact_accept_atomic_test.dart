import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'support/timed_native_store.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
bool _acceptsContact(List<KvLogOp> ops) => ops.whereType<PutOp>().any(
  (op) =>
      op.namespace == Ns.contacts &&
      (jsonDecode(utf8.decode(op.value)) as Map)['s'] ==
          ContactStatus.accepted.index,
);
bool _hasReply(List<KvLogOp> ops) =>
    ops.whereType<PutOp>().any((op) => op.namespace == Ns.outboxIndex);

class _Fault extends TimedNativeStore {
  _Fault(AsyncKvLogStore inner, this.mode) : super(inner, Stopwatch(), (_) {});
  final String mode;
  bool armed = false, blockRead = false;
  @override
  Future<Uint8List?> get(int ns, Uint8List key) {
    if (blockRead && ns == Ns.contacts) {
      throw StateError('injected readback refusal');
    }
    return super.get(ns, key);
  }

  final entered = Completer<void>(), release = Completer<void>();
  final committed = <List<KvLogOp>>[];
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final contact = _acceptsContact(ops), frame = _hasReply(ops);
    final match = mode == 'reject-contact' || mode == 'reply-contact'
        ? contact
        : frame;
    if (armed && match && mode != 'healthy') {
      armed = false;
      entered.complete();
      if (mode == 'hold-frame' || mode == 'close') await release.future;
      if (mode == 'reject-frame' || mode == 'reject-contact') {
        throw StateError('PRIVATE_CONTACT_ACCEPT_CANARY commit refusal');
      }
      final result = await super.commit(ops);
      committed.add(List.of(ops));
      if (mode == 'readback-denied') {
        blockRead = true;
        throw StateError('PRIVATE_CONTACT_ACCEPT_CANARY commit reply loss');
      }
      if (mode == 'reply-frame' || mode == 'reply-contact') {
        throw StateError('PRIVATE_CONTACT_ACCEPT_CANARY commit reply loss');
      }
      return result;
    }
    final result = await super.commit(ops);
    committed.add(List.of(ops));
    return result;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(bytes));
  }
}

void main() {
  setUp(errorJournal.clear);
  tearDown(errorJournal.clear);
  for (final native in [false, true]) {
    test(
      'acceptance preserves indexes, owned wire, existing age and conflicts native=$native',
      () async {
        Directory? dir;
        final fake = FakeKvLogStore();
        late AsyncSpaceOpener open;
        if (native) {
          expect(ensureHiddenVolumeLoaded(), true);
          dir = await Directory.systemTemp.createTemp('xveil-accept-index-');
          final path = '${dir.path}/store.hv';
          HvKvLogStore(
            hv.HvSpace.create(
              path: path,
              password: Uint8List.fromList(utf8.encode('fixture')),
              argon: hv.ArgonPreset.min,
            ),
          ).close();
          open = workerSpaceOpener(path);
        } else {
          open = ({required password, required bool create}) async =>
              SyncWrappedAsyncKvLogStore(fake);
        }
        final storage = HiddenVolumeStorage.async(open);
        try {
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            true,
          );
          for (var i = 2; i < 33; i++) {
            await storage.upsertContact(Contact(nodeId: _id(i)));
          }
          Uint8List reply(NodeId peer) => const WireEnvelope.accept()
              .withFrameId('accept:${peer.hex}')
              .encode();
          final fresh = _id(99);
          await storage.acceptContactAndEnqueue(
            fresh,
            'accept:${fresh.hex}',
            reply(fresh),
          );
          final ids = (await storage.loadConversations())
              .map((c) => c.peer.nodeId.hex)
              .toSet();
          expect(
            ids,
            containsAll([for (var i = 2; i < 33; i++) _id(i).hex, fresh.hex]),
          );
          final owned = _id(100), bytes = reply(_id(100));
          final expected = Uint8List.fromList(bytes);
          final pending = storage.acceptContactAndEnqueue(
            owned,
            'accept:${owned.hex}',
            bytes,
          );
          bytes.fillRange(0, bytes.length, 0);
          await pending;
          expect(
            (await storage.pendingOutboxFrames())
                .singleWhere((f) => f.peerHex == owned.hex)
                .wire,
            expected,
          );
          final existing = _id(101);
          await storage.upsertContact(
            Contact(
              nodeId: existing,
              status: ContactStatus.pendingIncoming,
              name: 'keep',
            ),
          );
          await storage.enqueueOutboxFrame(
            'accept:${existing.hex}',
            existing.hex,
            reply(existing),
          );
          final age = (await storage.pendingOutboxFrames())
              .singleWhere((f) => f.peerHex == existing.hex)
              .enqueuedAtMs;
          await storage.acceptContactAndEnqueue(
            existing,
            'accept:${existing.hex}',
            reply(existing),
          );
          expect(
            (await storage.pendingOutboxFrames())
                .singleWhere((f) => f.peerHex == existing.hex)
                .enqueuedAtMs,
            age,
          );
          expect((await storage.getContact(existing))?.name, 'keep');
          for (final wireConflict in [false, true]) {
            final peer = _id(wireConflict ? 103 : 102);
            await storage.upsertContact(
              Contact(nodeId: peer, status: ContactStatus.pendingIncoming),
            );
            await storage.enqueueOutboxFrame(
              'accept:${peer.hex}',
              wireConflict ? peer.hex : _id(2).hex,
              wireConflict ? Uint8List.fromList([1, 2, 3]) : reply(peer),
            );
            await expectLater(
              storage.acceptContactAndEnqueue(
                peer,
                'accept:${peer.hex}',
                reply(peer),
              ),
              throwsStateError,
            );
            expect(
              (await storage.getContact(peer))?.status,
              ContactStatus.pendingIncoming,
            );
          }
          await storage.close();
          expect(await storage.open(password: 'fixture'), true);
          expect(
            (await storage.getContact(fresh))?.status,
            ContactStatus.accepted,
          );
          expect(
            (await storage.pendingOutboxFrames())
                .singleWhere((f) => f.peerHex == owned.hex)
                .wire,
            expected,
          );
        } finally {
          await storage.close();
          await dir?.delete(recursive: true);
        }
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
    for (final mode in [
      'healthy',
      'hold-frame',
      'reject-frame',
      'reply-frame',
      'reject-contact',
      'reply-contact',
      'close',
      'callback',
      'readback-denied',
    ]) {
      test(
        'primary contact acceptance is atomic native=$native mode=$mode',
        () async {
          Directory? dir;
          final fake = FakeKvLogStore();
          late AsyncSpaceOpener open;
          late _Fault fault;
          if (native) {
            expect(ensureHiddenVolumeLoaded(), true);
            dir = await Directory.systemTemp.createTemp('xveil-accept-atomic-');
            final path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode('fixture')),
                argon: hv.ArgonPreset.min,
              ),
            ).close();
            open = workerSpaceOpener(path);
          } else {
            open = ({required password, required bool create}) async =>
                SyncWrappedAsyncKvLogStore(fake);
          }
          final storage = HiddenVolumeStorage.async(({
            required password,
            required bool create,
          }) async {
            final inner = await open(password: password, create: create);
            return inner == null ? null : fault = _Fault(inner, mode);
          });
          final wire = _Wire(), peer = _id(2);
          final service = MessagingService(wire, storage);
          Future<void>? accepting;
          Object? error;
          final published = <ContactStatus>[];
          var failCallback = mode == 'callback';
          service.onContactStatusChanged = (_, status) {
            published.add(status);
            if (failCallback) {
              throw StateError(
                'PRIVATE_CONTACT_ACCEPT_CANARY publication refusal',
              );
            }
          };
          final original = Contact(
            nodeId: peer,
            status: ContactStatus.pendingIncoming,
            name: 'fixture contact',
            pinned: true,
            archived: true,
            retentionDays: 12,
            allowPeerDelete: false,
          );
          try {
            expect(
              await storage.open(password: 'fixture', createIfMissing: true),
              true,
            );
            await storage.upsertContact(original);
            final commits = fault.committed;
            commits.clear();
            fault.armed = true;
            accepting = service.acceptContact(peer).catchError((Object e) {
              error = e;
            });
            if (mode == 'hold-frame' || mode == 'close') {
              await fault.entered.future;
            } else {
              await accepting;
            }
            fault.blockRead = false;
            final contact = await storage.getContact(peer);
            final rawReply = await fault.inner.get(
              Ns.outboxIndex,
              Uint8List.fromList(
                crypto.sha256.convert(utf8.encode('accept:${peer.hex}')).bytes,
              ),
            );
            expect(
              contact?.status == ContactStatus.accepted,
              rawReply != null,
              reason: 'a committed acceptance must always own a durable reply',
            );
            if (mode == 'hold-frame' ||
                mode == 'close' ||
                mode == 'reject-frame' ||
                mode == 'reject-contact') {
              expect(published, isEmpty);
              expect(wire.sent, isEmpty);
              expect(contact?.status, ContactStatus.pendingIncoming);
            }
            if (mode == 'close') {
              var closed = false;
              final closing = service.dispose().then((_) => closed = true);
              await pumpEventQueue();
              expect(
                closed,
                false,
                reason: 'dispose must join accepted contact transactions',
              );
              fault.release.complete();
              await accepting;
              await closing;
              expect(published, isEmpty);
              expect(wire.sent, isEmpty);
            }
            if (mode == 'hold-frame') fault.release.complete();
            await accepting;
            if (mode == 'reject-frame' ||
                mode == 'reject-contact' ||
                mode == 'callback' ||
                mode == 'readback-denied') {
              expect(error, isA<StateError>());
              final diagnostic = errorJournal.entries
                  .where((entry) => entry.kind == 'contact-accept')
                  .single;
              expect(
                diagnostic.message,
                isNot(contains('PRIVATE_CONTACT_ACCEPT_CANARY')),
              );
              expect(
                jsonEncode(diagnostic.toJson()),
                isNot(contains('PRIVATE_CONTACT_ACCEPT_CANARY')),
              );
            } else {
              expect(error, isNull);
              expect(
                errorJournal.entries.where((e) => e.kind == 'contact-accept'),
                isEmpty,
              );
            }
            if (mode == 'readback-denied') expect(published, isEmpty);
            // Retrying an uncertain transaction must adopt the durable frame,
            // not publish a second acceptance with a different logical ID.
            failCallback = false;
            if (mode != 'close') await service.acceptContact(peer);
            expect(
              commits.any((ops) => _acceptsContact(ops) && _hasReply(ops)),
              true,
              reason: 'status and response must share a native transaction',
            );
            if (mode != 'close') {
              expect(published, isNotEmpty);
              expect(wire.sent.any((e) => e.kind == WireKind.accept), true);
            }
            await service.dispose();
            await storage.close();
            expect(await storage.open(password: 'fixture'), true);
            final cold = (await storage.getContact(peer))!;
            expect(cold.status, ContactStatus.accepted);
            expect(cold.name, original.name);
            expect(cold.pinned, original.pinned);
            expect(cold.archived, original.archived);
            expect(cold.retentionDays, original.retentionDays);
            expect(cold.allowPeerDelete, original.allowPeerDelete);
            final replies = (await storage.pendingOutboxFrames())
                .where((f) => f.frameId == 'accept:${peer.hex}')
                .toList();
            expect(replies, hasLength(1));
            expect(replies.single.peerHex, peer.hex);
            expect(
              WireEnvelope.decode(replies.single.wire).kind,
              WireKind.accept,
            );
          } finally {
            if (!fault.release.isCompleted) fault.release.complete();
            await accepting;
            await service.dispose();
            await wire.dispose();
            await storage.close();
            await dir?.delete(recursive: true);
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
  }
}
