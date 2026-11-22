import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Admission extends HiddenVolumeStorage {
  _Admission(super.opener, this.mode);
  _Admission.async(super.opener, this.mode) : super.async();
  final String mode;
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = true;

  @override
  Future<ContactAcceptanceAdmission?> acceptContactAndEnqueue(
    NodeId peer,
    String id,
    Uint8List wire, {
    bool replyOnly = false,
  }) async {
    if (!armed || !replyOnly) {
      return super.acceptContactAndEnqueue(
        peer,
        id,
        wire,
        replyOnly: replyOnly,
      );
    }
    armed = false;
    entered.complete();
    if (mode == 'hold' || mode == 'superseded') await release.future;
    if (mode == 'before') throw StateError('PRIVATE_REQUEST_SECRET');
    if (mode == 'filesystem') {
      throw const FileSystemException(
        'PRIVATE_REQUEST_SECRET',
        '/private/PRIVATE_DESTINATION',
        OSError('PRIVATE_OS_MESSAGE', 13),
      );
    }
    if (mode == 'format') {
      throw const FormatException('PRIVATE_REQUEST_SECRET', 'PRIVATE_SOURCE');
    }
    final result = await super.acceptContactAndEnqueue(
      peer,
      id,
      wire,
      replyOnly: replyOnly,
    );
    if (mode == 'after') throw StateError('PRIVATE_REQUEST_SECRET');
    return result;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  final replyAttempts = <(int, WireEnvelope)>[];
  final directAcks = <(NodeId, String?)>[];
  bool rejectReply = false;

  @override
  Future<void> send(
    NodeId dst,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final envelope = WireEnvelope.decode(bytes);
    sent.add(envelope);
    if (envelope.kind == WireKind.ack) directAcks.add((dst, envelope.id));
  }

  @override
  Future<void> sendReply(int replyId, Uint8List bytes) async {
    replyAttempts.add((replyId, WireEnvelope.decode(bytes)));
    if (rejectReply) throw StateError('reply circuit is gone');
  }
}

Future<(_Admission, Directory?)> _storage(bool native, String mode) async {
  if (native) {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    final dir = await Directory.systemTemp.createTemp('xveil-contact-ack-');
    final path = '${dir.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: Uint8List.fromList(utf8.encode('fixture')),
        argon: hv.ArgonPreset.min,
      ),
    ).close();
    return (_Admission.async(workerSpaceOpener(path), mode), dir);
  }
  final kv = FakeKvLogStore();
  return (
    _Admission(({required password, required bool create}) => kv, mode),
    null,
  );
}

void main() {
  for (final kind in [WireKind.accept, WireKind.request, WireKind.reconnect]) {
    for (final rejectReply in [false, true]) {
      test('repeated handshake receipt uses an independent route '
          'kind=$kind rejectReply=$rejectReply', () async {
        final kv = FakeKvLogStore();
        final storage = HiddenVolumeStorage(
          ({required password, required create}) => kv,
        );
        final wire = _Wire()..rejectReply = rejectReply;
        final service = MessagingService(wire, storage);
        addTearDown(() async {
          await service.dispose();
          await wire.dispose();
          await storage.close();
        });
        expect(
          await storage.open(password: 'fixture', createIfMissing: true),
          isTrue,
        );
        final peer = _id(2), device = _id(3), other = _id(4);
        for (final identity in [peer, other]) {
          await storage.upsertContact(
            Contact(
              nodeId: identity,
              status: kind == WireKind.accept
                  ? ContactStatus.pendingOutgoing
                  : ContactStatus.accepted,
            ),
          );
        }
        const frameId = 'repeat-contact-handshake';
        final envelope = switch (kind) {
          WireKind.accept => const WireEnvelope.accept(),
          WireKind.request => const WireEnvelope.request('', id: 'intro'),
          _ => const WireEnvelope.reconnect(''),
        };
        final payload = envelope.withFrameId(frameId).encode();
        InboundMessage received(NodeId identity, int replyId) => InboundMessage(
          src: identity,
          srcDevice: identity == peer ? device : null,
          provenance: SenderProvenance.sessionPeer,
          replyId: replyId,
          payload: payload,
        );
        await service.deliverInbound(received(peer, 41));
        expect(wire.replyAttempts.map((e) => e.$1), [41]);
        final firstReceipt = wire.replyAttempts.single.$2;
        expect(firstReceipt.kind, WireKind.ack);
        expect(firstReceipt.id, frameId);
        expect(wire.directAcks, isEmpty);

        // Local admission can also report success while the ACK is lost.
        // Exercise both forms by replaying through the very same circuit.
        await service.deliverInbound(received(peer, 41));
        expect(wire.directAcks, [(device, frameId)]);
        expect(wire.replyAttempts.map((e) => e.$1), [41]);
        await service.deliverInbound(received(other, 42));
        expect(wire.directAcks, [(device, frameId)]);
        expect(wire.replyAttempts.map((e) => e.$1), [41, 42]);
      });
    }
  }

  for (final native in [false, true]) {
    for (final pendingIncoming in [false, true]) {
      test(
        'accept waits for local outgoing consent native=$native pendingIncoming=$pendingIncoming',
        () async {
          final (storage, dir) = await _storage(native, 'hold');
          final wire = _Wire(), peer = _id(2);
          final service = MessagingService(wire, storage);
          addTearDown(() async {
            await service.dispose();
            await wire.dispose();
            await storage.close();
            await dir?.delete(recursive: true);
          });
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            isTrue,
          );
          if (pendingIncoming) {
            await storage.prepareContactRequest(peer, incoming: true);
          }
          var declined = 0;
          const frameId = 'accept-with-outgoing-consent';
          final inbound = InboundMessage(
            src: peer,
            payload: const WireEnvelope.accept().withFrameId(frameId).encode(),
            provenance: SenderProvenance.signed,
            onDeclined: (_) => declined++,
          );
          await service.deliverInbound(inbound);
          expect(
            declined,
            1,
            reason:
                'the mailbox copy still belongs to a possible requesting device',
          );
          expect(wire.sent, isEmpty);
          expect(
            (await storage.getContact(peer))?.status,
            pendingIncoming ? ContactStatus.pendingIncoming : null,
          );

          // Deliver the still-available copy when this device has the outgoing
          // intent. The earlier local refusal must not consume its frame ID.
          await storage.prepareContactRequest(peer, incoming: false);
          await service.deliverInbound(inbound);
          expect(declined, 1);
          expect(
            (await storage.getContact(peer))?.status,
            ContactStatus.accepted,
          );
          expect(wire.directAcks, [(peer, frameId)]);
          await service.deliverInbound(
            InboundMessage(
              src: peer,
              payload: const WireEnvelope.message(
                'first reply',
                id: 'reply',
              ).encode(),
              provenance: SenderProvenance.signed,
              onDeclined: (_) => declined++,
            ),
          );
          expect(declined, 1);
          expect(
            (await storage.loadMessages(peer.hex)).single.body,
            'first reply',
          );
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }

    for (final reconnect in [false, true]) {
      for (final mode in [
        'hold',
        'superseded',
        'before',
        'after',
        if (!native && !reconnect) ...['filesystem', 'format'],
      ]) {
        test(
          'contact request ACK follows acceptance admission native=$native reconnect=$reconnect mode=$mode',
          () async {
            final (storage, dir) = await _storage(native, mode);
            final wire = _Wire(), peer = _id(2);
            final service = MessagingService(wire, storage);
            Future<void>? received;
            var declined = 0;
            const fid = 'stable-handshake';
            final frame =
                (reconnect
                        ? const WireEnvelope.reconnect('')
                        : const WireEnvelope.request('', id: 'intro'))
                    .withFrameId(fid)
                    .encode();
            InboundMessage message() => InboundMessage(
              src: peer,
              payload: frame,
              provenance: SenderProvenance.sessionPeer,
              onDeclined: (_) => declined++,
            );
            Iterable<WireEnvelope> acks() =>
                wire.sent.where((e) => e.kind == WireKind.ack && e.id == fid);
            errorJournal.clear();
            try {
              expect(
                await storage.open(password: 'fixture', createIfMissing: true),
                isTrue,
              );
              await storage.upsertContact(
                Contact(nodeId: peer, status: ContactStatus.accepted),
              );
              service.start();
              received = service.deliverInbound(message());
              await storage.entered.future;
              if (mode != 'hold' && mode != 'superseded') await received;
              expect(
                acks(),
                isEmpty,
                reason:
                    'sender must retain request until durable response admission',
              );
              if (mode == 'hold') {
                expect(await storage.pendingOutboxFrames(), isEmpty);
                storage.release.complete();
                await received;
                expect(declined, 0);
              } else if (mode == 'superseded') {
                await service.blockContact(peer);
                storage.release.complete();
                await received;
                expect(
                  declined,
                  1,
                  reason:
                      'no durable reply was committed before the decision changed',
                );
                expect(acks(), isEmpty);
                expect(await storage.pendingOutboxFrames(), isEmpty);
                await service.unblockContact(peer);
                await service.deliverInbound(message());
                expect(declined, 1);
              } else {
                expect(
                  declined,
                  1,
                  reason:
                      'relay must keep its copy after local persistence failure',
                );
                expect(
                  (await storage.pendingOutboxFrames()).isNotEmpty,
                  mode == 'after',
                );
                final failure = errorJournal.entries.lastWhere(
                  (e) => e.kind == 'contact-request-persist',
                );
                expect(
                  failure.type,
                  mode == 'filesystem'
                      ? 'FileSystemException'
                      : mode == 'format'
                      ? 'FormatException'
                      : 'StateError',
                );
                if (mode == 'filesystem') expect(failure.numericCode, 13);
                expect(failure.message, isNot(contains('PRIVATE_')));
                expect(
                  jsonEncode(failure.toJson()),
                  isNot(contains('PRIVATE_')),
                );
                // Warm retry must not be silenced by an early frame-seen entry.
                await service.deliverInbound(message());
              }
              expect(acks(), hasLength(1));
              final acceptId =
                  (await storage.pendingOutboxFrames()).single.frameId;
              expect(acceptId, startsWith('accept:${peer.hex}:'));
              // A later identical request can repair an already-ACKed response.
              await storage.ackOutboxFrame(acceptId, fromPeerHex: peer.hex);
              await service.deliverInbound(message());
              expect(acks(), hasLength(2));
              final retryId =
                  (await storage.pendingOutboxFrames()).single.frameId;
              expect(retryId, startsWith('accept:${peer.hex}:'));
              expect(retryId, isNot(acceptId));
              await service.dispose();
              await storage.close();
              expect(await storage.open(password: 'fixture'), isTrue);
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == retryId,
                ),
                isTrue,
              );
              expect(
                (await storage.getContact(peer))?.status,
                ContactStatus.accepted,
              );
            } finally {
              if (!storage.release.isCompleted) storage.release.complete();
              await received;
              await service.dispose();
              await wire.dispose();
              await storage.close();
              await dir?.delete(recursive: true);
              errorJournal.clear();
            }
          },
          skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
        );
      }
    }
  }
}
