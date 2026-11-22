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
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _GreetingStorage extends HiddenVolumeStorage {
  _GreetingStorage() : this._(FakeKvLogStore());
  _GreetingStorage._(FakeKvLogStore kv)
    : super(({required password, required create}) => kv);
  _GreetingStorage.native(String path) : super.async(workerSpaceOpener(path));

  final entered = Completer<void>(), release = Completer<void>();
  bool holdQueueRead = false;
  bool failGreetingStatus = false;

  @override
  Future<List<OutboxFrame>> pendingOutboxFrames() async {
    if (holdQueueRead) {
      holdQueueRead = false;
      entered.complete();
      await release.future;
    }
    return super.pendingOutboxFrames();
  }

  @override
  Future<bool> markMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) {
    if (failGreetingStatus && status == MessageStatus.sent) {
      failGreetingStatus = false;
      return Future.value(false);
    }
    return super.markMessageStatus(conversationId, messageId, status);
  }
}

InboundMessage _from(NodeId peer, WireEnvelope envelope) => InboundMessage(
  src: peer,
  payload: envelope.encode(),
  provenance: SenderProvenance.sessionPeer,
);

class _HeldAcceptance extends LoopbackTransport {
  _HeldAcceptance({this.ackId}) : super(localNodeId: _id(1));
  final String? ackId;
  final entered = Completer<void>(), release = Completer<void>();
  final sent = <WireEnvelope>[];
  final inbound = StreamController<InboundMessage>.broadcast();
  void inject(InboundMessage message) => inbound.add(message);
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Future<void> dispose() async {
    await inbound.close();
    await super.dispose();
  }

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final envelope = WireEnvelope.decode(payload);
    sent.add(envelope);
    final hold = ackId == null
        ? envelope.kind == WireKind.accept
        : envelope.kind == WireKind.ack && envelope.id == ackId;
    if (hold && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }
}

void main() {
  for (final native in [false, true]) {
    group(
      'greetings after contact acceptance (native: $native)',
      () {
        final peer = _id(2);
        late _GreetingStorage storage;
        late _HeldAcceptance transport;
        late MessagingService service;

        WireEnvelope acceptance(String frameId) => WireEnvelope.accept(
          contactRequestId: transport.sent
              .lastWhere((frame) => frame.kind == WireKind.request)
              .contactRequestId,
        ).withFrameId(frameId);

        setUp(() async {
          if (native) {
            expect(ensureHiddenVolumeLoaded(), isTrue);
            final dir = await Directory.systemTemp.createTemp(
              'xveil-contact-greeting-',
            );
            addTearDown(() => dir.delete(recursive: true));
            final path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode('fixture')),
                argon: hv.ArgonPreset.min,
              ),
            ).close();
            storage = _GreetingStorage.native(path);
          } else {
            storage = _GreetingStorage();
          }
          transport = _HeldAcceptance();
          service = MessagingService(transport, storage);
          addTearDown(() async {
            if (!storage.release.isCompleted) storage.release.complete();
            await service.dispose();
            await transport.dispose();
            await storage.close();
          });
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            isTrue,
          );
        });

        test(
          'an empty request cannot acknowledge the first ordinary message',
          () async {
            await service.submitContactRequest(peer, '');
            storage.holdQueueRead = true;
            final accepting = service.deliverInbound(
              _from(peer, acceptance('accept-empty')),
            );
            try {
              await storage.entered.future;
              expect(
                (await storage.getContact(peer))?.status,
                ContactStatus.accepted,
              );
              expect(
                await service.sendText(peer, 'first ordinary message'),
                isTrue,
              );
            } finally {
              storage.release.complete();
              await accepting;
            }

            final row = (await storage.loadMessages(peer.hex)).single;
            expect(row.status, MessageStatus.sent);
            await service.flushOutbox();
            expect(
              transport.sent.where(
                (e) => e.kind == WireKind.message && e.id == row.id,
              ),
              hasLength(2),
            );
            await service.deliverInbound(_from(peer, WireEnvelope.ack(row.id)));
            expect(
              (await storage.loadMessageById(peer.hex, row.id))?.status,
              MessageStatus.delivered,
            );
          },
        );

        test(
          'two admitted greetings each wait for their own receipt',
          () async {
            await service.submitContactRequest(peer, 'first greeting');
            await service.submitContactRequest(peer, 'second greeting');
            final initial = await storage.loadMessages(peer.hex);
            expect(initial.map((m) => m.status), [
              MessageStatus.sending,
              MessageStatus.sending,
            ]);

            await service.deliverInbound(
              _from(peer, acceptance('accept-two')),
            );

            expect(
              (await storage.loadMessages(peer.hex)).map((m) => m.status),
              [MessageStatus.sent, MessageStatus.sent],
            );
            expect(await storage.pendingOutboxFrames(), isEmpty);
            await service.flushOutbox();
            expect(
              transport.sent
                  .where((e) => e.kind == WireKind.message)
                  .map((e) => e.id),
              unorderedEquals(initial.map((m) => m.id)),
            );
            await service.deliverInbound(
              _from(peer, WireEnvelope.ack(initial.first.id)),
            );
            expect(
              (await storage.loadMessageById(
                peer.hex,
                initial.first.id,
              ))?.status,
              MessageStatus.delivered,
            );
            expect(
              (await storage.loadMessageById(
                peer.hex,
                initial.last.id,
              ))?.status,
              MessageStatus.sent,
            );
          },
        );

        for (final requestReceiptFirst in [false, true]) {
          test(
            'an interrupted greeting handoff recovers after reopen (receipt first: $requestReceiptFirst)',
            () async {
              await service.submitContactRequest(peer, 'offline greeting');
              final request = (await storage.pendingOutboxFrames()).single;
              final greeting = (await storage.loadMessages(peer.hex)).single;
              // Simulate stopping after the relationship committed but before the
              // service could transfer the greeting out of the handshake queue.
              expect(
                await storage.acceptOutgoingContactRequest(
                  peer,
                  requestId: WireEnvelope.decode(request.wire).contactRequestId,
                ),
                isTrue,
              );
              await service.dispose();
              await storage.close();
              expect(await storage.open(password: 'fixture'), isTrue);
              service = MessagingService(transport, storage);
              if (requestReceiptFirst) {
                await service.deliverInbound(
                  _from(peer, WireEnvelope.ack(request.frameId)),
                );
              } else {
                await service.debugFlushOutboxFrames();
              }
              expect(
                (await storage.loadMessageById(peer.hex, greeting.id))?.status,
                MessageStatus.sent,
              );
              expect(await storage.pendingOutboxFrames(), isEmpty);
              await service.flushOutbox();
              expect(
                transport.sent.where(
                  (e) => e.kind == WireKind.message && e.id == greeting.id,
                ),
                hasLength(1),
              );
            },
          );
        }

        test(
          'a refused greeting status write retains the request and ACKs acceptance',
          () async {
            await service.submitContactRequest(peer, 'queued greeting');
            final request = (await storage.pendingOutboxFrames()).single;
            final greeting = (await storage.loadMessages(peer.hex)).single;
            final published = <ContactStatus>[];
            service.onContactStatusChanged = (who, status) {
              if (who == peer) published.add(status);
            };
            const acceptanceId = 'accept-write-fails';
            storage.failGreetingStatus = true;
            await service.deliverInbound(
              _from(peer, acceptance(acceptanceId)),
            );

            expect(
              (await storage.getContact(peer))?.status,
              ContactStatus.accepted,
            );
            expect(
              (await storage.pendingOutboxFrames()).single.frameId,
              request.frameId,
            );
            expect(
              (await storage.loadMessageById(peer.hex, greeting.id))?.status,
              MessageStatus.sending,
            );
            expect(
              transport.sent.where(
                (e) => e.kind == WireKind.ack && e.id == acceptanceId,
              ),
              hasLength(1),
            );
            expect(published, [ContactStatus.accepted]);

            await service.debugFlushOutboxFrames();
            expect(await storage.pendingOutboxFrames(), isEmpty);
            expect(
              (await storage.loadMessageById(peer.hex, greeting.id))?.status,
              MessageStatus.sent,
            );
          },
        );

        test(
          'greeting cleanup failure does not fail a committed local accept',
          () async {
            await service.submitContactRequest(peer, 'your greeting');
            final request = (await storage.pendingOutboxFrames()).single;
            await service.deliverInbound(
              _from(
                peer,
                const WireEnvelope.request('their greeting', id: 'intro'),
              ),
            );
            expect(
              (await storage.getContact(peer))?.status,
              ContactStatus.pendingIncoming,
            );
            final published = <ContactStatus>[];
            service.onContactStatusChanged = (who, status) {
              if (who == peer) published.add(status);
            };
            storage.failGreetingStatus = true;
            transport.release.complete();
            await expectLater(service.acceptContact(peer), completes);

            expect(
              (await storage.getContact(peer))?.status,
              ContactStatus.accepted,
            );
            expect(published, [ContactStatus.accepted]);
            final retained = await storage.pendingOutboxFrames();
            expect(retained.map((f) => f.frameId), contains(request.frameId));
            final accept = retained.singleWhere(
              (f) => f.frameId.startsWith('accept:'),
            );
            expect(
              transport.sent.map((e) => e.frameId),
              contains(accept.frameId),
            );
          },
        );
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
  }

  for (final alreadyAccepted in [false, true]) {
    test(
      'acceptance receipt does not hold ingress (already accepted: $alreadyAccepted)',
      () async {
        const receiptId = 'accepted-with-ack';
        final transport = _HeldAcceptance(ackId: receiptId);
        final storage = HiddenVolumeStorage(
          ({required password, required create}) => FakeKvLogStore(),
        );
        final peer = _id(2);
        final service = MessagingService(transport, storage);
        var updates = 0;
        final changes = service.changes.listen((_) => updates++);
        addTearDown(() async {
          if (!transport.release.isCompleted) transport.release.complete();
          await changes.cancel();
          await service.dispose();
          await transport.dispose();
          await storage.close();
        });
        expect(
          await storage.open(password: 'fixture', createIfMissing: true),
          isTrue,
        );
        await storage.upsertContact(
          Contact(
            nodeId: peer,
            status: alreadyAccepted
                ? ContactStatus.accepted
                : ContactStatus.pendingOutgoing,
          ),
        );
        InboundMessage from(WireEnvelope envelope) => InboundMessage(
          src: peer,
          payload: envelope.encode(),
          provenance: SenderProvenance.sessionPeer,
        );
        var receiptFinished = false;
        final accept = service
            .deliverInbound(
              from(const WireEnvelope.accept().withFrameId(receiptId)),
            )
            .then((_) => receiptFinished = true);
        await transport.entered.future;
        await pumpEventQueue();
        expect(
          (await storage.getContact(peer))?.status,
          ContactStatus.accepted,
        );
        final updatedBeforeFollowingMessage = updates != 0;
        final message = service.deliverInbound(
          from(const WireEnvelope.message('after accept', id: 'post-accept')),
          waitForReceipts: false,
        );
        await pumpEventQueue();
        try {
          expect(receiptFinished, isFalse);
          expect(
            await storage.loadMessageById(peer.hex, 'post-accept'),
            isNotNull,
          );
          if (!alreadyAccepted) expect(updatedBeforeFollowingMessage, isTrue);
        } finally {
          transport.release.complete();
          await accept;
          await message;
        }
      },
    );
  }

  for (final native in [false, true]) {
    for (final reconnect in [false, true]) {
      test(
        'contact acceptance network wait releases ingress native=$native reconnect=$reconnect',
        () async {
          Directory? dir;
          late HiddenVolumeStorage storage;
          if (native) {
            expect(ensureHiddenVolumeLoaded(), isTrue);
            dir = await Directory.systemTemp.createTemp(
              'xveil-contact-ingress-',
            );
            final path = '${dir.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode('fixture')),
                argon: hv.ArgonPreset.min,
              ),
            ).close();
            storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
          } else {
            final kv = FakeKvLogStore();
            storage = HiddenVolumeStorage(
              ({required password, required bool create}) => kv,
            );
          }
          final transport = _HeldAcceptance();
          final peer = _id(2);
          final messaging = MessagingService(transport, storage)
            // The oracle is the unreleased gate, never a timeout winning a race.
            ..liveLegDeadline = const Duration(days: 1);
          try {
            expect(
              await storage.open(password: 'fixture', createIfMissing: true),
              isTrue,
            );
            await storage.upsertContact(
              Contact(nodeId: peer, status: ContactStatus.accepted),
            );
            messaging.start();
            var calls = 0;
            messaging.onCallSignal = (_, signal) {
              expect(signal.type, CallSignalType.offer);
              calls++;
            };
            final request = reconnect
                ? const WireEnvelope.reconnect('')
                : const WireEnvelope.request('', id: 'intro');
            final handling = messaging.deliverInbound(
              InboundMessage(
                src: peer,
                payload: request.withFrameId('intro-frame').encode(),
                provenance: SenderProvenance.sessionPeer,
              ),
            );
            var requestSettled = false;
            final settled = handling.then((_) => requestSettled = true);
            await transport.entered.future;
            transport.inject(
              InboundMessage(
                src: peer,
                payload: WireEnvelope.callSignal(
                  const CallSignal(
                    callId: 'test-call',
                    type: CallSignalType.offer,
                  ).encode(),
                ).encode(),
                provenance: SenderProvenance.sessionPeer,
              ),
            );
            // Await actual durable worker round trips, not a guessed sleep.
            for (var i = 0; i < 30; i++) {
              await storage.getContact(peer);
              await pumpEventQueue(times: 3);
            }
            expect(transport.release.isCompleted, isFalse);
            expect(
              calls,
              1,
              reason: 'ordinary call offer was held behind acceptance egress',
            );
            expect(
              requestSettled,
              isTrue,
              reason: 'ingress must wait for durable admission only',
            );
            // Fresh wire IDs must not create an unbounded detached send per
            // request while the same logical acceptance is already in flight.
            for (var i = 0; i < 8; i++) {
              await messaging.deliverInbound(
                InboundMessage(
                  src: peer,
                  payload: request.withFrameId('intro-frame/$i').encode(),
                  provenance: SenderProvenance.sessionPeer,
                ),
              );
            }
            expect(
              transport.sent.where((e) => e.kind == WireKind.accept),
              hasLength(1),
            );
            final queued = await storage.pendingOutboxFrames();
            final accept = queued
                .where(
                  (f) =>
                      f.peerHex == peer.hex &&
                      WireEnvelope.decode(f.wire).kind == WireKind.accept,
                )
                .single;
            expect(accept.frameId, startsWith('accept:${peer.hex}:'));
            expect(
              (await storage.getContact(peer))?.status,
              ContactStatus.accepted,
            );
            var closed = false;
            final close = messaging.dispose().then((_) => closed = true);
            await pumpEventQueue();
            expect(
              closed,
              isFalse,
              reason: 'dispose must join the actual active response',
            );
            transport.release.complete();
            await settled;
            await close;
            expect(closed, isTrue);
            await storage.close();
            expect(await storage.open(password: 'fixture'), isTrue);
            expect(
              (await storage.pendingOutboxFrames()).any(
                (f) => f.frameId == accept.frameId,
              ),
              isTrue,
            );
          } finally {
            if (!transport.release.isCompleted) transport.release.complete();
            await messaging.dispose();
            await transport.dispose();
            await storage.close();
            await dir?.delete(recursive: true);
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
  }
}
