import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/large_frame.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/state/ratchet_persistence.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Link implements VeilTransport {
  _Link(this.id);
  final NodeId id;
  final input = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  bool supportsFragments = true;
  bool Function(Uint8List)? deliver;
  Future<void> Function(NodeId, Uint8List)? beforeSend;
  final sent = <Uint8List>[];
  @override
  Future<NodeId> nodeId() async => id;
  @override
  Stream<InboundMessage> messages() => input.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    if (anonymous && payload.length > 6144) {
      throw StateError('native authenticated payload cap');
    }
    await beforeSend?.call(dst, payload);
    sent.add(Uint8List.fromList(payload));
    if (deliver?.call(payload) == false ||
        (isLargeFrame(payload) && peer?.supportsFragments == false)) {
      return;
    }
    peer?.input.add(
      InboundMessage(
        src: id,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => [];
  @override
  Future<void> dispose() => input.close();
}

void main() {
  test(
    'a large post is delivered once and acknowledged through a capped live link',
    () async {
      final a = _Link(_id(1)), b = _Link(_id(2));
      a.peer = b;
      b.peer = a;
      final sa = HiddenVolumeStorage(
        ({required password, required bool create}) => FakeKvLogStore(),
      );
      final sb = HiddenVolumeStorage(
        ({required password, required bool create}) => FakeKvLogStore(),
      );
      await sa.open(password: 'a');
      await sb.open(password: 'b');
      await sa.upsertContact(
        Contact(nodeId: b.id, status: ContactStatus.accepted),
      );
      await sb.upsertContact(
        Contact(nodeId: a.id, status: ContactStatus.accepted),
      );
      final ma = MessagingService(a, sa, anonymous: true)..start();
      final mb = MessagingService(b, sb, anonymous: true)..start();
      addTearDown(() async {
        await ma.dispose();
        await mb.dispose();
        await a.dispose();
        await b.dispose();
      });
      final random = Random(702);
      final text = base64Encode(
        List.generate(16384, (_) => random.nextInt(256)),
      );
      expect(await ma.sendText(b.id, text), isTrue);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline)) {
        if ((await sa.loadMessages(b.id.hex)).single.status ==
            MessageStatus.delivered) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final received = await sb.loadMessages(a.id.hex);
      expect(received, hasLength(1));
      expect(received.single.body, text);
      expect(
        (await sa.loadMessages(b.id.hex)).single.status,
        MessageStatus.delivered,
      );
      expect(a.sent.every((p) => p.length <= 6144), isTrue);
    },
  );
  test(
    'the compatibility band still reaches a receiver without fragment support',
    () async {
      final r = await _rig();
      r.b.supportsFragments = false;
      final text = List.filled(5000, 'x').join();
      expect(await r.ma.sendText(r.b.id, text), isTrue);
      await _until(
        () async =>
            (await r.sa.loadMessages(r.b.id.hex)).single.status ==
            MessageStatus.delivered,
      );
      expect((await r.sb.loadMessages(r.a.id.hex)).single.body, text);
      expect(r.a.sent.any(isLargeFrame), isTrue);
      expect(
        r.a.sent.any(
          (p) =>
              !isLargeFrame(p) &&
              WireEnvelope.decode(p).kind == WireKind.message,
        ),
        isTrue,
      );
    },
  );
  test(
    'ordinary nonanonymous delivery keeps its existing large-frame path',
    () async {
      final r = await _rig(anonymous: false);
      final text = List.filled(20000, 'x').join();
      expect(await r.ma.sendText(r.b.id, text), isTrue);
      await _until(
        () async => (await r.sb.loadMessages(r.a.id.hex)).isNotEmpty,
      );
      expect(r.a.sent.any(isLargeFrame), isFalse);
    },
  );
  test(
    'one missing part leaves no ACK and can be completed by that part alone',
    () async {
      final r = await _rig();
      r.a.peer = null;
      await r.ma.sendText(r.b.id, _longText());
      final parts = r.a.sent.where(isLargeFrame).toList();
      final id = (await r.sa.loadMessages(r.b.id.hex)).single.id;
      for (var i = 0; i < parts.length; i++) {
        if (i != 3) await r.deliver(parts[i]);
      }
      expect(await r.sb.loadMessages(r.a.id.hex), isEmpty);
      expect(_acks(r.b.sent, id), 0);
      await r.deliver(parts[3]);
      expect((await r.sb.loadMessages(r.a.id.hex)).single.body, _longText());
      expect(_acks(r.b.sent, id), 1);
    },
  );
  test(
    'receiver restart forgets partial RAM and a whole resend repairs delivery',
    () async {
      final r = await _rig();
      r.a.peer = null;
      await r.ma.sendText(r.b.id, _longText());
      final parts = r.a.sent.where(isLargeFrame).toList();
      for (final f in parts.take(parts.length ~/ 2)) {
        await r.deliver(f);
      }
      expect(await r.sb.loadMessages(r.a.id.hex), isEmpty);
      await r.restartReceiver();
      for (final f in parts) {
        await r.deliver(f);
      }
      expect((await r.sb.loadMessages(r.a.id.hex)).single.body, _longText());
      expect(
        (await r.sb.loadEventsSince(r.a.id.hex, r.a.id.hex, 0)),
        hasLength(1),
      );
    },
  );
  test(
    'a lost whole-message ACK is repaired after restart without a second post',
    () async {
      final r = await _rig();
      r.b.deliver = (p) => WireEnvelope.decode(p).kind != WireKind.ack;
      await r.ma.sendText(r.b.id, _longText());
      await _until(
        () async => (await r.sb.loadMessages(r.a.id.hex)).isNotEmpty,
      );
      expect(
        (await r.sa.loadMessages(r.b.id.hex)).single.status,
        MessageStatus.sent,
      );
      await r.restartReceiver();
      r.b.deliver = null;
      await r.ma.flushOutbox();
      await _until(
        () async =>
            (await r.sa.loadMessages(r.b.id.hex)).single.status ==
            MessageStatus.delivered,
      );
      expect(await r.sb.loadMessages(r.a.id.hex), hasLength(1));
    },
  );
  test(
    'failed post persistence leaves the original retryable and never ACKs its parts',
    () async {
      final r = await _rig();
      r.rawB.refuseMessages = true;
      await r.ma.sendText(r.b.id, _longText());
      final id = (await r.sa.loadMessages(r.b.id.hex)).single.id;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await r.sb.loadMessages(r.a.id.hex), isEmpty);
      expect(_acks(r.b.sent, id), 0);
      r.rawB.refuseMessages = false;
      for (final f in r.a.sent.where(isLargeFrame).toList()) {
        await r.deliver(f);
      }
      expect((await r.sb.loadMessages(r.a.id.hex)).single.body, _longText());
    },
  );
  test(
    'large edits keep one original durable frame until receiver persistence succeeds',
    () async {
      final r = await _rig();
      await r.ma.sendText(r.b.id, 'original');
      await _until(
        () async => (await r.sb.loadMessages(r.a.id.hex)).isNotEmpty,
      );
      final id = (await r.sa.loadMessages(r.b.id.hex)).single.id;
      r.rawB.refuseMessages = true;
      await r.ma.editOwnMessage(id, _longText());
      expect(
        (await r.sa.pendingOutboxFrames()).where(
          (f) => WireEnvelope.decode(f.wire).kind == WireKind.edit,
        ),
        isNotEmpty,
      );
      expect((await r.sb.loadMessages(r.a.id.hex)).single.body, 'original');
      r.rawB.refuseMessages = false;
      r.clock = r.clock.add(const Duration(minutes: 1));
      await r.ma.flushOutbox();
      await _until(
        () async =>
            (await r.sb.loadMessages(r.a.id.hex)).single.body == _longText(),
      );
      await _until(
        () async => (await r.sa.pendingOutboxFrames())
            .where((f) => WireEnvelope.decode(f.wire).kind == WireKind.edit)
            .isEmpty,
      );
      expect((await r.sb.loadMessageHistory(r.a.id.hex, id)), hasLength(2));
    },
  );
  test(
    'claimed or unaccepted fragments cannot poison a later authorized transfer',
    () async {
      final r = await _rig();
      r.a.peer = null;
      await r.ma.sendText(r.b.id, _longText());
      final parts = r.a.sent.where(isLargeFrame).toList();
      for (final f in parts) {
        await r.deliver(f, proof: SenderProvenance.claimed);
      }
      expect(await r.sb.loadMessages(r.a.id.hex), isEmpty);
      await r.sb.upsertContact(
        Contact(nodeId: r.a.id, status: ContactStatus.pendingIncoming),
      );
      for (final f in parts) {
        await r.deliver(f);
      }
      expect(await r.sb.loadMessages(r.a.id.hex), isEmpty);
      await r.sb.upsertContact(
        Contact(nodeId: r.a.id, status: ContactStatus.accepted),
      );
      for (final f in parts) {
        await r.deliver(f);
      }
      expect(await r.sb.loadMessages(r.a.id.hex), hasLength(1));
    },
  );
  test(
    'a message partly received while blocked remains hidden after unblock',
    () async {
      final r = await _rig();
      r.a.peer = null;
      await r.ma.sendText(r.b.id, _longText());
      final parts = r.a.sent.where(isLargeFrame).toList();
      await r.sb.upsertContact(
        Contact(nodeId: r.a.id, status: ContactStatus.blocked),
      );
      await r.deliver(parts.first);
      await r.sb.upsertContact(
        Contact(nodeId: r.a.id, status: ContactStatus.accepted),
      );
      for (final f in parts.skip(1)) {
        await r.deliver(f);
      }
      expect(await r.sb.loadMessages(r.a.id.hex), isEmpty);
      expect(await r.mb.heldWhileBlocked(r.a.id), 1);
      expect(await r.mb.releaseHeldWhileBlocked(r.a.id), 1);
      expect((await r.sb.loadMessages(r.a.id.hex)).single.body, _longText());
    },
  );
  test(
    'changing routes between parts cannot split one transfer across devices',
    () async {
      final r = await _rig();
      var route = r.b.id;
      final later = _id(3);
      r.ma.routeFor = (_) => route;
      final destinations = <NodeId>[];
      r.a.beforeSend = (dst, p) async {
        if (isLargeFrame(p)) {
          destinations.add(dst);
          route = later;
        }
      };
      await r.ma.sendText(r.b.id, _longText());
      expect(destinations, isNotEmpty);
      expect(destinations.toSet(), {r.b.id});
    },
  );
  test(
    'each part reserves its native ratchet position across a reservation boundary',
    () async {
      final r = await _rig();
      final native = _Ratchet(r.b.id);
      r.ma.ratchet = RatchetPersistence(native: native, storage: r.sa);
      r.a.beforeSend = (dst, payload) async {
        if (!isLargeFrame(payload)) return;
        final marks = decodeRatchetReservations(
          await r.sa.getSetting(ratchetReservationKey(native.key)),
        );
        expect(
          marks.any((m) => m.next > native.sent),
          isTrue,
          reason: 'every published fragment must fit its durable reservation',
        );
        native.seal();
      };
      await r.ma.sendText(r.b.id, List.filled(65536, 'x').join());
      expect(native.sent, greaterThan(RatchetPersistence.reserveAhead));
      expect(native.exports, greaterThan(1));
      await _until(
        () async =>
            (await r.sa.loadMessages(r.b.id.hex)).single.status ==
            MessageStatus.delivered,
      );
    },
  );
  test(
    'an overlapping retry joins the existing large send instead of duplicating parts',
    () async {
      final r = await _rig();
      final entered = Completer<void>(), release = Completer<void>();
      var calls = 0;
      r.a.beforeSend = (dst, p) async {
        if (isLargeFrame(p)) {
          calls++;
          if (calls == 1) {
            entered.complete();
            await release.future;
          }
        }
      };
      final send = r.ma.sendText(r.b.id, _longText());
      await entered.future;
      final retry = r.ma.flushOutbox();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 1);
      release.complete();
      await send;
      await retry;
      final frames = r.a.sent.where(isLargeFrame).toList();
      expect(frames, hasLength(parseLargeFrame(frames.first).count));
    },
  );
  test(
    'shutdown joins the active fragment send and publishes no following parts',
    () async {
      final r = await _rig();
      final entered = Completer<void>(), release = Completer<void>();
      var first = true;
      r.a.beforeSend = (dst, p) async {
        if (isLargeFrame(p) && first) {
          first = false;
          entered.complete();
          await release.future;
        }
      };
      final send = r.ma.sendText(r.b.id, _longText());
      final sendFailed = expectLater(send, throwsStateError);
      await entered.future;
      var closed = false;
      final closing = r.ma.dispose().then((_) {
        closed = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(closed, isFalse);
      release.complete();
      await closing;
      await sendFailed;
      expect(r.a.sent.where(isLargeFrame), hasLength(1));
    },
  );
  for (final show in [false, true]) {
    test(
      'a completed blocked compatibility copy is not held again after user choice ($show)',
      () async {
        final r = await _rig();
        r.a.peer = null;
        await r.ma.sendText(r.b.id, List.filled(5000, 'x').join());
        final whole = r.a.sent.firstWhere(
          (p) =>
              !isLargeFrame(p) &&
              WireEnvelope.decode(p).kind == WireKind.message,
        );
        final parts = r.a.sent.where(isLargeFrame).toList();
        await r.sb.upsertContact(
          Contact(nodeId: r.a.id, status: ContactStatus.blocked),
        );
        await r.deliver(whole);
        await r.deliver(parts.first);
        await r.sb.upsertContact(
          Contact(nodeId: r.a.id, status: ContactStatus.accepted),
        );
        if (show) {
          expect(await r.mb.releaseHeldWhileBlocked(r.a.id), 1);
        } else {
          await r.mb.discardHeldWhileBlocked(r.a.id);
        }
        for (final p in parts.skip(1)) {
          await r.deliver(p);
        }
        expect(await r.mb.heldWhileBlocked(r.a.id), 0);
        expect(await r.sb.loadMessages(r.a.id.hex), hasLength(show ? 1 : 0));
      },
    );
  }
}

String _longText() =>
    base64Encode(List.generate(16384, (i) => (i * 71 + i ~/ 13) % 256));
int _acks(List<Uint8List> frames, String id) => frames
    .where(
      (p) =>
          !isLargeFrame(p) &&
          WireEnvelope.decode(p).kind == WireKind.ack &&
          WireEnvelope.decode(p).id == id,
    )
    .length;
Future<void> _until(Future<bool> Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(end)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('fixture condition did not converge');
}

class _RefusingStore extends FakeKvLogStore {
  bool refuseMessages = false;
  @override
  int commit(List<KvLogOp> ops) {
    if (refuseMessages &&
        ops.whereType<AppendLogOp>().any(
          (op) => op.namespace >= Ns.messageLogShardFirst,
        )) {
      throw StateError('injected message persistence refusal');
    }
    return super.commit(ops);
  }
}

class _Rig {
  final a = _Link(_id(11)), b = _Link(_id(12));
  final rawA = _RefusingStore(), rawB = _RefusingStore();
  late HiddenVolumeStorage sa, sb;
  late MessagingService ma, mb;
  late bool anonymous;
  var clock = DateTime.now();
  Future<void> deliver(
    Uint8List p, {
    SenderProvenance proof = SenderProvenance.sessionPeer,
  }) => mb.deliverInbound(
    InboundMessage(src: a.id, payload: p, provenance: proof),
  );
  Future<void> restartReceiver() async {
    await mb.dispose();
    mb = MessagingService(b, sb, anonymous: anonymous, now: () => clock)
      ..start();
  }
}

Future<_Rig> _rig({bool anonymous = true}) async {
  final r = _Rig()..anonymous = anonymous;
  r.a.peer = r.b;
  r.b.peer = r.a;
  r.sa = HiddenVolumeStorage(
    ({required password, required bool create}) => r.rawA,
  );
  r.sb = HiddenVolumeStorage(
    ({required password, required bool create}) => r.rawB,
  );
  await r.sa.open(password: 'a');
  await r.sb.open(password: 'b');
  await r.sa.upsertContact(
    Contact(nodeId: r.b.id, status: ContactStatus.accepted),
  );
  await r.sb.upsertContact(
    Contact(nodeId: r.a.id, status: ContactStatus.accepted),
  );
  r.ma = MessagingService(r.a, r.sa, anonymous: anonymous, now: () => r.clock)
    ..start();
  r.mb = MessagingService(r.b, r.sb, anonymous: anonymous, now: () => r.clock)
    ..start();
  addTearDown(() async {
    await r.ma.dispose();
    await r.mb.dispose();
    await r.a.dispose();
    await r.b.dispose();
  });
  return r;
}

class _Ratchet implements RatchetStateHandle {
  _Ratchet(NodeId peer) {
    key = Uint8List(kRatchetKeyLen)..fillRange(0, kRatchetKeyLen, 11);
    key.setRange(
      kRatchetKeyPeerNodeOffset,
      kRatchetKeyPeerNodeOffset + 32,
      peer.bytes,
    );
  }
  late final Uint8List key;
  final chain = Uint8List(32)..fillRange(0, 32, 73);
  int sent = 0, exports = 0;
  bool dirty = false;
  void seal() {
    sent++;
    dirty = true;
  }

  @override
  int stateVersion() => sent;
  @override
  List<Uint8List> list() => [Uint8List.fromList(key)];
  @override
  RatchetSendPosition sendPosition(Uint8List key) =>
      RatchetSendPosition(Uint8List.fromList(chain), sent);
  @override
  List<RatchetSendPosition> sendPositions(Uint8List key) => [sendPosition(key)];
  @override
  Uint8List export(Uint8List key) {
    exports++;
    return Uint8List.fromList([sent & 255, (sent >> 8) & 255, ...chain]);
  }

  @override
  List<RatchetSendPosition> storedSendPositions(
    Uint8List key,
    Uint8List blob,
  ) => [
    RatchetSendPosition(
      Uint8List.fromList(blob.sublist(2)),
      blob[0] | (blob[1] << 8),
    ),
  ];
  @override
  ({List<Uint8List> keys, int remaining, int generation}) peekDirty(
    int maxKeys,
  ) => (
    keys: dirty ? [Uint8List.fromList(key)] : [],
    remaining: 0,
    generation: sent,
  );
  @override
  int ackDirty(List<Uint8List> keys, int generation) {
    if (generation == sent && dirty) {
      dirty = false;
      return 1;
    }
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
