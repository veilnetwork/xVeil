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
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/ratchet_persistence.dart';

NodeId _id(int value) => NodeId(Uint8List(32)..fillRange(0, 32, value));

class _HeldStore extends HiddenVolumeStorage {
  _HeldStore(super.open) : super.async();
  bool holdContact = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Contact?> getContact(NodeId peer) async {
    final contact = await super.getContact(peer);
    if (holdContact && peer == _id(2)) {
      holdContact = false;
      entered.complete();
      await release.future;
    }
    return contact;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> send(
    NodeId peer,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    sent.add(frame);
    if (frame.frameId == 'edit:first' && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }
}

class _Sink implements MailboxSink {
  final sent = <WireEnvelope>[];
  Future<void> Function()? onStash;
  @override
  bool get isRegistered => true;
  @override
  bool backgroundDrainPaused = false;
  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async {
    sent.add(WireEnvelope.decode(payload));
    await onStash?.call();
  }
  @override
  void nudgeDrain() {}
  @override
  void noteActivity() {}
}

class _HeldReservation extends Fake implements RatchetPersistence {
  final entered = Completer<void>(), release = Completer<void>();

  @override
  bool get degraded => false;

  @override
  Future<void> reserveBeforePublish(NodeId peer) async {
    if (entered.isCompleted) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<int> flush({String why = 'unknown', bool now = false}) async => 0;

  @override
  Future<int> close() async => 0;

  @override
  Future<int> forgetPeer(NodeId peer) async => 0;
}

Future<_HeldStore> _openStore(bool native) async {
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    final dir = await Directory.systemTemp.createTemp('xveil-outbox-consent-');
    addTearDown(() => dir.delete(recursive: true));
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
  final storage = _HeldStore(open);
  addTearDown(storage.close);
  expect(
    await storage.open(password: 'fixture', createIfMissing: true),
    isTrue,
  );
  return storage;
}

Future<void> _ackAcceptance(
  MessagingService service,
  HiddenVolumeStorage storage,
  NodeId peer,
  String id,
) async {
  await service.deliverInbound(
    InboundMessage(
      src: peer,
      payload: WireEnvelope.ack(id).encode(),
      provenance: SenderProvenance.sessionPeer,
    ),
  );
  // The ingress starts retirement separately. Read the durable queue until its
  // deletion is visible before creating any replacement.
  for (var i = 0; i < 50; i++) {
    final pending = await storage.pendingOutboxFrames();
    if (!pending.any((frame) => frame.frameId == id)) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('The peer acknowledgement did not retire its acceptance');
}

void main() {
  for (final native in [false, true]) {
    for (final (change, timedOut) in [
      ('ack', false),
      ('ack', true),
      ('block and unblock', false),
      ('cancel request', false),
      ('other peer ack', false),
    ]) {
      test('live handshake verifies outbox admission after ratchet reservation '
          'native=$native change=$change timeout=$timedOut', () async {
        final storage = await _openStore(native);
        final wire = _Wire(), peer = _id(2), other = _id(3);
        final ratchet = _HeldReservation();
        final service = MessagingService(wire, storage)
          ..ratchet = ratchet
          ..liveLegDeadline = timedOut
              ? Duration.zero
              : const Duration(days: 1);
        final request = change == 'cancel request';
        final fid = '${request ? 'request' : 'accept'}:${peer.hex}:persisted';
        addTearDown(wire.dispose);
        addTearDown(service.dispose);
        addTearDown(() {
          if (!ratchet.release.isCompleted) ratchet.release.complete();
        });
        for (final contact in [peer, other]) {
          await storage.upsertContact(
            Contact(
              nodeId: contact,
              status: request && contact == peer
                  ? ContactStatus.pendingOutgoing
                  : ContactStatus.accepted,
            ),
          );
        }
        final frame = request
            ? const WireEnvelope.request('')
            : const WireEnvelope.accept();
        await storage.enqueueOutboxFrame(
          fid,
          peer.hex,
          frame.withFrameId(fid).encode(),
        );
        final flush = service.debugFlushOutboxFrames();
        await ratchet.entered.future;
        if (timedOut) await flush;
        expect(wire.sent, isEmpty);
        if (change == 'block and unblock') {
          await service.blockContact(peer);
          await service.unblockContact(peer);
        } else if (change == 'ack') {
          await _ackAcceptance(service, storage, peer, fid);
        } else if (request) {
          expect(await service.cancelRequest(peer), isTrue);
          expect(await storage.getContact(peer), isNull);
          expect(
            (await service.submitContactRequest(peer, '')).admitted,
            isTrue,
          );
        } else {
          await service.deliverInbound(
            InboundMessage(
              src: other,
              payload: WireEnvelope.ack(fid).encode(),
              provenance: SenderProvenance.sessionPeer,
            ),
          );
        }

        ratchet.release.complete();
        await flush;
        await pumpEventQueue();
        expect(
          wire.sent.where((frame) => frame.frameId == fid),
          hasLength(change == 'other peer ack' ? 1 : 0),
        );
        final pending = await storage.pendingOutboxFrames();
        if (request) {
          expect(pending.single.frameId, isNot(fid));
          expect(wire.sent.single.frameId, pending.single.frameId);
        } else {
          expect(pending.isEmpty, change == 'ack');
        }
      }, skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null);
    }

    for (final legacy in [false, true]) {
      test('duplicate receipt leaves a new handshake response pending '
          'native=$native legacy=$legacy', () async {
        final storage = await _openStore(native);
        final wire = _Wire(), peer = _id(2);
        final service = MessagingService(wire, storage);
        addTearDown(wire.dispose);
        addTearDown(service.dispose);
        await storage.upsertContact(
          Contact(
            nodeId: peer,
            status: legacy
                ? ContactStatus.accepted
                : ContactStatus.pendingIncoming,
          ),
        );
        if (legacy) {
          final id = 'accept:${peer.hex}';
          await storage.enqueueOutboxFrame(
            id,
            peer.hex,
            const WireEnvelope.accept().withFrameId(id).encode(),
          );
        } else {
          await service.acceptContact(peer);
        }
        final first = (await storage.pendingOutboxFrames()).single;
        Future<void> receive(WireEnvelope envelope) => service.deliverInbound(
          InboundMessage(
            src: peer,
            payload: envelope.encode(),
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        Future<void> acknowledge(String id) async {
          await receive(WireEnvelope.ack(id));
          // Join the outbox lane after the ACK's async retirement starts.
          await storage.ackOutboxFrame('test-fence', fromPeerHex: peer.hex);
        }

        await receive(
          const WireEnvelope.request('').withFrameId('request:old'),
        );
        final retry = (await storage.pendingOutboxFrames()).single;
        expect(retry.frameId, first.frameId);
        expect(retry.enqueuedAtMs, first.enqueuedAtMs);
        await acknowledge(first.frameId);
        expect(await storage.pendingOutboxFrames(), isEmpty);
        await receive(
          const WireEnvelope.request('').withFrameId('request:new'),
        );
        final second = (await storage.pendingOutboxFrames()).single;
        await acknowledge(first.frameId);
        expect(await storage.containsOutboxFrame(second), isTrue);
        expect(second.frameId, isNot(first.frameId));

        await receive(
          const WireEnvelope.request('').withFrameId('request:new'),
        );
        expect(
          (await storage.pendingOutboxFrames()).single.frameId,
          second.frameId,
        );
        await acknowledge(second.frameId);
        expect(await storage.pendingOutboxFrames(), isEmpty);
      }, skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null);
    }
    test(
      'accepting after conversation removal replaces the old reply native=$native',
      () async {
        final storage = await _openStore(native);
        final wire = _Wire(), peer = _id(2);
        final service = MessagingService(wire, storage);
        addTearDown(wire.dispose);
        addTearDown(service.dispose);
        final pending = Contact(
          nodeId: peer,
          status: ContactStatus.pendingIncoming,
        );
        await storage.upsertContact(pending);
        await service.acceptContact(peer);
        final old = (await storage.pendingOutboxFrames()).single;
        await storage.removeConversation(peer);
        await storage.upsertContact(pending);
        await service.acceptContact(peer);
        final next = (await storage.pendingOutboxFrames()).single;
        expect(next.frameId, isNot(old.frameId));
        await storage.ackOutboxFrame(old.frameId, fromPeerHex: peer.hex);
        expect(await storage.containsOutboxFrame(next), isTrue);

        await service.dispose();
        await storage.close();
        expect(await storage.open(password: 'fixture'), isTrue);
        expect(
          (await storage.getContact(peer))?.status,
          ContactStatus.accepted,
        );
        expect(
          (await storage.pendingOutboxFrames()).single.frameId,
          next.frameId,
        );
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
    for (final source in ['accept', 'outbox']) {
      test(
        'ack retires $source still resolving the mailbox native=$native',
        () async {
          final storage = await _openStore(native);
          final wire = _Wire(), sink = _Sink(), peer = _id(2);
          final lookupStarted = Completer<void>(), lookup = Completer<bool>();
          final service = MessagingService(wire, storage)
            ..attachMailbox(sink)
            ..isOwnDevice = (destination) {
              if (destination != peer || lookupStarted.isCompleted) {
                return Future.value(false);
              }
              lookupStarted.complete();
              return lookup.future;
            };
          addTearDown(wire.dispose);
          addTearDown(service.dispose);
          addTearDown(() {
            if (!lookup.isCompleted) lookup.complete(false);
          });
          await storage.upsertContact(
            Contact(
              nodeId: peer,
              status: source == 'accept'
                  ? ContactStatus.pendingIncoming
                  : ContactStatus.accepted,
            ),
          );
          final id = 'accept:${peer.hex}';
          if (source == 'outbox') {
            await storage.enqueueOutboxFrame(
              id,
              peer.hex,
              const WireEnvelope.accept().withFrameId(id).encode(),
            );
          }
          final work = source == 'accept'
              ? service.acceptContact(peer)
              : service.debugFlushOutboxFrames();
          await lookupStarted.future;
          await work;
          expect(sink.sent, isEmpty);
          final reply = (await storage.pendingOutboxFrames()).single;
          await _ackAcceptance(service, storage, peer, reply.frameId);
          lookup.complete(false);
          await Future<void>.delayed(Duration.zero);
          expect(sink.sent, isEmpty);
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
    for (final acceptedAtRelay in [false, true]) {
      test('retired deposit does not settle a replacement native=$native '
          'old deposit succeeded=$acceptedAtRelay', () async {
        final storage = await _openStore(native);
        final wire = _Wire(), sink = _Sink(), peer = _id(2);
        final entered = Completer<void>(), held = Completer<void>();
        sink.onStash = () {
          sink.onStash = null;
          entered.complete();
          return held.future;
        };
        final service = MessagingService(wire, storage)..attachMailbox(sink);
        addTearDown(wire.dispose);
        addTearDown(service.dispose);
        addTearDown(() {
          if (!held.isCompleted) held.complete();
        });
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.pendingIncoming),
        );
        final accepting = service.acceptContact(peer);
        await entered.future;
        await accepting;
        final reply = (await storage.pendingOutboxFrames()).single;
        await _ackAcceptance(service, storage, peer, reply.frameId);
        await service.deliverInbound(
          InboundMessage(
            src: peer,
            payload: const WireEnvelope.request('').encode(),
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        expect(
          (await storage.pendingOutboxFrames()).single.frameId,
          startsWith('accept:${peer.hex}:'),
        );
        expect(sink.sent, hasLength(1));
        if (acceptedAtRelay) {
          held.complete();
        } else {
          held.completeError(StateError('PeerUnresolved'));
        }
        await Future<void>.delayed(Duration.zero);
        await service.debugFlushOutboxFrames();
        expect(sink.sent.map((env) => env.kind), [
          WireKind.accept,
          WireKind.accept,
        ]);
      }, skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null);
    }

    for (final source in ['initial-request', 'retry', 'accept', 'outbox']) {
      for (final decision in ['none', 'block', 'block-unblock']) {
        test('mailbox uses current contact consent native=$native '
            'source=$source decision=$decision', () async {
          final storage = await _openStore(native);
          final wire = _Wire(), sink = _Sink(), peer = _id(2);
          final lookupStarted = Completer<void>();
          final lookupResult = Completer<bool>();
          final service = MessagingService(wire, storage)
            ..attachMailbox(sink)
            ..isOwnDevice = (destination) async {
              if (destination != peer) return false;
              if (!lookupStarted.isCompleted) lookupStarted.complete();
              return lookupResult.future;
            };
          addTearDown(wire.dispose);
          addTearDown(service.dispose);
          addTearDown(() {
            if (!lookupResult.isCompleted) lookupResult.complete(false);
          });
          if (source != 'initial-request') {
            await storage.upsertContact(
              Contact(
                nodeId: peer,
                status: switch (source) {
                  'accept' => ContactStatus.pendingIncoming,
                  'retry' => ContactStatus.pendingOutgoing,
                  _ => ContactStatus.accepted,
                },
              ),
            );
          }
          if (source == 'outbox') {
            final id = 'accept:${peer.hex}';
            await storage.enqueueOutboxFrame(
              id,
              peer.hex,
              const WireEnvelope.accept().withFrameId(id).encode(),
            );
          }
          final work = switch (source) {
            'initial-request' => service.submitContactRequest(peer, ''),
            'retry' => service.resendRequest(peer),
            'accept' => service.acceptContact(peer),
            _ => service.debugFlushOutboxFrames(),
          };
          await lookupStarted.future;
          // For background stashes, finish the live leg or even the full
          // flush. That alone must not revoke a valid pending deposit.
          if (source == 'accept' || source == 'outbox') await work;
          expect(sink.sent, isEmpty);
          if (decision != 'none') await service.blockContact(peer);
          if (decision == 'block-unblock') {
            await service.unblockContact(peer);
          }
          lookupResult.complete(false);
          await work;
          await Future<void>.delayed(Duration.zero);
          final expectedKind = source == 'accept' || source == 'outbox'
              ? WireKind.accept
              : WireKind.request;
          expect(
            sink.sent.map((frame) => frame.kind),
            decision == 'none' ? [expectedKind] : isEmpty,
          );
        }, skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null);
      }
    }
    for (final stage in ['contact', 'worker']) {
      for (final change in [
        'block',
        'block-unblock',
        'ack',
        'other-peer',
        'none',
      ]) {
        test(
          'Outbox consent native=$native stage=$stage change=$change',
          () async {
            final storage = await _openStore(native);
            final wire = _Wire(), sink = _Sink();
            final service = MessagingService(wire, storage)
              ..liveLegDeadline = const Duration(days: 1)
              ..attachMailbox(sink);
            Future<void>? flushing;
            final peer = _id(2), fid = 'accept:${_id(2).hex}';
            try {
              await storage.upsertContact(
                Contact(nodeId: peer, status: ContactStatus.accepted),
              );
              if (stage == 'worker') {
                await storage.enqueueOutboxFrame(
                  'edit:first',
                  peer.hex,
                  WireEnvelope.edit(
                    'message',
                    'first',
                    seq: 1,
                  ).withFrameId('edit:first').encode(),
                );
              }
              final wireBytes = const WireEnvelope.accept()
                  .withFrameId(fid)
                  .encode();
              await storage.enqueueOutboxFrame(fid, peer.hex, wireBytes);
              storage.holdContact = stage == 'contact';
              flushing = service.debugFlushOutboxFrames();
              await (stage == 'contact'
                  ? storage.entered.future
                  : wire.entered.future);
              if (change.startsWith('block')) {
                await service.blockContact(peer);
                if (change == 'block-unblock') {
                  await service.unblockContact(peer);
                }
              } else if (change == 'other-peer') {
                await service.blockContact(_id(3));
              } else if (change == 'ack') {
                await service.deliverInbound(
                  InboundMessage(
                    src: peer,
                    payload: WireEnvelope.ack(fid).encode(),
                    provenance: SenderProvenance.sessionPeer,
                  ),
                );
              }
              if (!storage.release.isCompleted) storage.release.complete();
              if (!wire.release.isCompleted) wire.release.complete();
              await flushing;
              final stale = change.startsWith('block') || change == 'ack';
              // The worker-stage deposit was already admitted before the block
              // or ACK. A later change cannot recall that earlier transport leg.
              final stashes = stage == 'worker'
                  ? 1
                  : stale
                  ? 0
                  : 1;
              expect(
                {
                  'live': wire.sent.where((f) => f.frameId == fid).length,
                  'mailbox': sink.sent.where((f) => f.frameId == fid).length,
                },
                {'live': stale ? 0 : 1, 'mailbox': stashes},
              );
              if (change == 'block-unblock') {
                await service.debugFlushOutboxFrames();
                expect(
                  wire.sent.where((f) => f.frameId == fid),
                  hasLength(1),
                  reason: 'cancelled candidates must not spend retry backoff',
                );
              }
              final expected = change == 'block'
                  ? ContactStatus.blocked
                  : ContactStatus.accepted;
              expect((await storage.getContact(peer))?.status, expected);
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == fid,
                ),
                change != 'ack',
              );
              await service.dispose();
              await storage.close();
              expect(await storage.open(password: 'fixture'), isTrue);
              expect((await storage.getContact(peer))?.status, expected);
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == fid,
                ),
                change != 'ack',
              );
            } finally {
              if (!storage.release.isCompleted) storage.release.complete();
              if (!wire.release.isCompleted) wire.release.complete();
              await flushing;
              await service.dispose();
              await wire.dispose();
            }
          },
          skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
        );
      }
    }
  }
}
