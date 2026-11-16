import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _FaultStore extends FakeKvLogStore {
  String? fault;
  @override
  int commit(List<KvLogOp> ops) {
    final mode = fault;
    final publishes = ops.whereType<PutOp>().any(
      (op) => op.namespace == Ns.outboxIndex,
    );
    if (mode == null || !publishes) return super.commit(ops);
    fault = null;
    if (mode == 'before') throw StateError('fixture retry publication refused');
    super.commit(ops);
    throw StateError('fixture retry publication reply lost');
  }
}

class _HeldQueue extends HiddenVolumeStorage {
  _HeldQueue(super.open) : super.async();
  bool hold = false;
  bool holdAdmission = false, _holdContact = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<bool> admitContactRequestRetry(
    OutboxFrame request, {
    OutboxFrame? expected,
    required bool Function() isCurrent,
  }) {
    if (holdAdmission) {
      holdAdmission = false;
      _holdContact = true;
    }
    return super.admitContactRequestRetry(
      request,
      expected: expected,
      isCurrent: isCurrent,
    );
  }

  @override
  Future<Contact?> getContact(NodeId peer) async {
    final value = await super.getContact(peer);
    if (_holdContact) {
      _holdContact = false;
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<List<OutboxFrame>> pendingOutboxFrames() async {
    final frames = await super.pendingOutboxFrames();
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return frames;
  }
}

class _Wire extends LoopbackTransport {
  _Wire(NodeId me) : super(localNodeId: me);
  final sent = <WireEnvelope>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(payload));
  }
}

class _Single {
  _Single(this.storage, this.wire, this.messaging, this.directory);
  final _HeldQueue storage;
  final _Wire wire;
  MessagingService messaging;
  final Directory? directory;
  Future<void> close() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await messaging.dispose();
    await wire.dispose();
    await storage.close();
    await directory?.delete(recursive: true);
  }
}

Future<_Single> _single(bool native) async {
  Directory? dir;
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    dir = await Directory.systemTemp.createTemp('xveil-retry-control-');
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
    final kv = FakeKvLogStore();
    open = ({required password, required bool create}) async =>
        SyncWrappedAsyncKvLogStore(kv);
  }
  final storage = _HeldQueue(open), wire = _Wire(_id(1));
  expect(
    await storage.open(password: 'fixture', createIfMissing: true),
    isTrue,
  );
  final fixture = _Single(storage, wire, MessagingService(wire, storage), dir);
  addTearDown(fixture.close);
  return fixture;
}

Future<void> _deliver(MessagingService to, NodeId from, WireEnvelope frame) =>
    to.deliverInbound(
      InboundMessage(
        src: from,
        payload: frame.encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );

void main() {
  for (final fault in ['before', 'after']) {
    test(
      'legacy retry preserves admission failure semantics: $fault',
      () async {
        final kv = _FaultStore();
        final storage = _HeldQueue(
          ({required password, required bool create}) async =>
              SyncWrappedAsyncKvLogStore(kv),
        );
        expect(await storage.open(password: 'fixture'), isTrue);
        final wire = _Wire(_id(1)), peer = _id(2);
        var messaging = MessagingService(wire, storage);
        try {
          await messaging.sendRequest(peer, 'hello');
          final first = (await storage.pendingOutboxFrames()).single;
          await storage.ackOutboxFrame(first.frameId, fromPeerHex: peer.hex);
          await messaging.dispose();
          messaging = MessagingService(wire, storage);
          wire.sent.clear();
          kv.fault = fault;
          await expectLater(messaging.resendRequest(peer), throwsStateError);
          expect(wire.sent, isEmpty);
          expect(
            await storage.pendingOutboxFrames(),
            hasLength(fault == 'before' ? 0 : 1),
          );
          await messaging.resendRequest(peer);
          final saved = (await storage.pendingOutboxFrames()).single;
          expect(saved.frameId, first.frameId);
          expect(
            wire.sent.singleWhere((w) => w.kind == WireKind.request).id,
            WireEnvelope.decode(first.wire).id,
          );
        } finally {
          await messaging.dispose();
          await wire.dispose();
          await storage.close();
        }
      },
    );
  }
  for (final native in [false, true]) {
    test(
      'durable block is authoritative without a service cache notice native=$native',
      () async {
        final f = await _single(native), peer = _id(2);
        await f.messaging.sendRequest(peer, 'hello');
        final original = (await f.storage.pendingOutboxFrames()).single;
        f.storage.hold = true;
        final retry = f.messaging.resendRequest(peer);
        await f.storage.entered.future;
        // Exercise an independently completed storage writer. A service-only
        // revision check cannot substitute for the guarded durable read.
        await f.storage.setContactStatus(peer, ContactStatus.blocked);
        f.wire.sent.clear();
        f.storage.release.complete();
        expect(await retry, isFalse);
        expect(f.wire.sent, isEmpty);
        final remaining = (await f.storage.pendingOutboxFrames()).single;
        expect(remaining.frameId, original.frameId);
        expect(remaining.wire, original.wire);
        expect(
          (await f.storage.getContact(peer))?.status,
          ContactStatus.blocked,
        );
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );

    for (final legacy in [false, true]) {
      for (final greeting in ['', 'hello']) {
        test(
          'unchanged request still retries legacy=$legacy empty=${greeting.isEmpty} native=$native',
          () async {
            final f = await _single(native), peer = _id(2);
            await f.messaging.sendRequest(peer, greeting);
            final original = f.wire.sent.singleWhere(
              (w) => w.kind == WireKind.request,
            );
            final before = (await f.storage.pendingOutboxFrames()).single;
            if (legacy) {
              // Model an older request predating durable control frames. This
              // local fixture retirement is not claimed to be a peer ACK.
              await f.storage.ackOutboxFrame(
                before.frameId,
                fromPeerHex: peer.hex,
              );
              await f.messaging.dispose();
              f.messaging = MessagingService(f.wire, f.storage);
            }
            f.wire.sent.clear();
            expect(
              await f.messaging.resendRequest(peer),
              isFalse,
            ); // No mailbox.
            final sent = f.wire.sent.singleWhere(
              (w) => w.kind == WireKind.request,
            );
            final after = (await f.storage.pendingOutboxFrames()).single;
            expect(WireEnvelope.decode(after.wire).id, sent.id);
            expect(sent.body, greeting);
            if (!legacy || greeting.isNotEmpty) expect(sent.id, original.id);
            if (!legacy) expect(after.enqueuedAtMs, before.enqueuedAtMs);
            if (greeting.isNotEmpty) {
              expect(sent.sentAtMs, original.sentAtMs);
              expect(sent.seq, original.seq);
            }
            f.wire.sent.clear();
            await f.messaging.resendRequest(peer);
            expect(
              f.wire.sent.singleWhere((w) => w.kind == WireKind.request).id,
              sent.id,
            );
            expect(
              (await f.storage.pendingOutboxFrames()).single.frameId,
              after.frameId,
            );
          },
          skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
        );
      }
    }

    test(
      'retired exact request is not recreated native=$native',
      () async {
        final f = await _single(native), peer = _id(2);
        await f.messaging.sendRequest(peer, 'hello');
        final original = (await f.storage.pendingOutboxFrames()).single;
        f.storage.hold = true;
        final retry = f.messaging.resendRequest(peer);
        await f.storage.entered.future;
        // Exact membership protects retirement independent of contact state.
        // Deliberate local fixture retirement, not a network ACK from a stranger.
        await f.storage.ackOutboxFrame(original.frameId, fromPeerHex: peer.hex);
        f.wire.sent.clear();
        f.storage.release.complete();
        expect(await retry, isFalse);
        expect(f.wire.sent, isEmpty);
        expect(await f.storage.pendingOutboxFrames(), isEmpty);
        expect(
          (await f.storage.getContact(peer))?.status,
          ContactStatus.pendingOutgoing,
        );
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );

    test(
      'block during retry admission prevents a legacy enqueue native=$native',
      () async {
        final f = await _single(native), peer = _id(2);
        await f.messaging.sendRequest(peer, 'hello');
        final original = (await f.storage.pendingOutboxFrames()).single;
        await f.storage.ackOutboxFrame(original.frameId, fromPeerHex: peer.hex);
        await f.messaging.dispose();
        f.messaging = MessagingService(f.wire, f.storage);
        f.storage.holdAdmission = true;
        f.wire.sent.clear();
        final retry = f.messaging.resendRequest(peer);
        await f.storage.entered.future;
        final block = f.messaging.blockContact(peer);
        f.storage.release.complete();
        expect(await retry, isFalse);
        await block;
        expect(f.wire.sent, isEmpty);
        expect(await f.storage.pendingOutboxFrames(), isEmpty);
        expect(f.messaging.pendingFramesFor(peer), 0);
        expect(
          (await f.storage.getContact(peer))?.status,
          ContactStatus.blocked,
        );
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );

    for (final decision in [
      'accepted',
      'blocked',
      'cancelled',
      'new-request',
    ]) {
      test(
        'late request retry after $decision native=$native',
        () async {
          Directory? dir;
          Future<_HeldQueue> storage(String name) async {
            late AsyncSpaceOpener open;
            if (native) {
              expect(ensureHiddenVolumeLoaded(), isTrue);
              dir ??= await Directory.systemTemp.createTemp(
                'xveil-retry-race-',
              );
              final path = '${dir!.path}/$name.hv';
              HvKvLogStore(
                hv.HvSpace.create(
                  path: path,
                  password: Uint8List.fromList(utf8.encode('fixture')),
                  argon: hv.ArgonPreset.min,
                ),
              ).close();
              open = workerSpaceOpener(path);
            } else {
              final kv = FakeKvLogStore();
              open = ({required password, required bool create}) async =>
                  SyncWrappedAsyncKvLogStore(kv);
            }
            final s = _HeldQueue(open);
            expect(
              await s.open(password: 'fixture', createIfMissing: true),
              isTrue,
            );
            return s;
          }

          final a = _id(1), b = _id(2);
          final sA = await storage('a'), sB = await storage('b');
          final tA = _Wire(a), tB = _Wire(b);
          final mA = MessagingService(tA, sA), mB = MessagingService(tB, sB);
          try {
            await mA.sendRequest(b, 'old greeting');
            final original = tA.sent.singleWhere(
              (f) => f.kind == WireKind.request,
            );
            sA.hold = true;
            final retry = mA.resendRequest(b);
            await sA.entered.future;
            String? freshId;
            if (decision == 'accepted') {
              await _deliver(mB, a, original);
              await mB.acceptContact(a);
              await _deliver(
                mA,
                b,
                tB.sent.singleWhere((f) => f.kind == WireKind.accept),
              );
            } else if (decision == 'blocked') {
              await mA.blockContact(b);
            } else {
              expect(await mA.cancelRequest(b), isTrue);
              if (decision == 'new-request') {
                await mA.sendRequest(b, 'fresh greeting');
                freshId = tA.sent
                    .lastWhere((f) => f.kind == WireKind.request)
                    .id;
              }
            }
            tA.sent.clear();
            sA.release.complete();
            expect(await retry, isFalse);
            final queued = await sA.pendingOutboxFrames();
            final expectedId = decision == 'blocked' ? original.id : freshId;
            expect(
              {
                'late_requests': tA.sent
                    .where((f) => f.kind == WireKind.request)
                    .length,
                'queued_ids': queued
                    .map((f) => WireEnvelope.decode(f.wire).id)
                    .toList(),
                'pending': mA.pendingFramesFor(b),
                'contact': (await sA.getContact(b))?.status.name,
              },
              {
                'late_requests': 0,
                'queued_ids': expectedId == null ? <String>[] : [expectedId],
                'pending': expectedId == null ? 0 : 1,
                'contact': switch (decision) {
                  'accepted' => 'accepted',
                  'blocked' => 'blocked',
                  'new-request' => 'pendingOutgoing',
                  _ => null,
                },
              },
            );
            if (decision == 'new-request') {
              expect((await sA.loadMessages(b.hex)).map((m) => m.body), [
                'fresh greeting',
              ]);
            }
          } finally {
            if (!sA.release.isCompleted) sA.release.complete();
            await mA.dispose();
            await mB.dispose();
            await tA.dispose();
            await tB.dispose();
            await sA.close();
            await sB.close();
            await dir?.delete(recursive: true);
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
  }
}
