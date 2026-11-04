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
  Future<void> enqueueOutboxFrame(
    String id,
    String peer,
    Uint8List wire,
  ) async {
    if (!armed || id != 'accept:$peer') {
      return super.enqueueOutboxFrame(id, peer, wire);
    }
    armed = false;
    entered.complete();
    if (mode == 'hold') await release.future;
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
    await super.enqueueOutboxFrame(id, peer, wire);
    if (mode == 'after') throw StateError('PRIVATE_REQUEST_SECRET');
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
  for (final native in [false, true]) {
    for (final reconnect in [false, true]) {
      for (final mode in [
        'hold',
        'before',
        'after',
        if (!native && !reconnect) ...['filesystem', 'format'],
      ]) {
        test(
          'contact request ACK follows acceptance admission native=$native reconnect=$reconnect mode=$mode',
          () async {
            Directory? dir;
            late _Admission storage;
            if (native) {
              expect(ensureHiddenVolumeLoaded(), isTrue);
              dir = await Directory.systemTemp.createTemp('xveil-contact-ack-');
              final path = '${dir.path}/store.hv';
              HvKvLogStore(
                hv.HvSpace.create(
                  path: path,
                  password: Uint8List.fromList(utf8.encode('fixture')),
                  argon: hv.ArgonPreset.min,
                ),
              ).close();
              storage = _Admission.async(workerSpaceOpener(path), mode);
            } else {
              final kv = FakeKvLogStore();
              storage = _Admission(
                ({required password, required bool create}) => kv,
                mode,
              );
            }
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
              if (mode != 'hold') await received;
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
              final acceptId = 'accept:${peer.hex}';
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == acceptId,
                ),
                isTrue,
              );
              // A later identical request can repair an already-ACKed response.
              await storage.ackOutboxFrame(acceptId, fromPeerHex: peer.hex);
              await service.deliverInbound(message());
              expect(acks(), hasLength(2));
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == acceptId,
                ),
                isTrue,
              );
              await service.dispose();
              await storage.close();
              expect(await storage.open(password: 'fixture'), isTrue);
              expect(
                (await storage.pendingOutboxFrames()).any(
                  (f) => f.frameId == acceptId,
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
