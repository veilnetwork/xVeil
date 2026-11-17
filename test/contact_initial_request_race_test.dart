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
    if (mode == null ||
        !ops.whereType<PutOp>().any((op) => op.namespace == Ns.outboxIndex)) {
      return super.commit(ops);
    }
    fault = null;
    if (mode == 'before') throw StateError('fixture initial admission refused');
    super.commit(ops);
    throw StateError('fixture initial admission reply lost');
  }
}

class _HeldGreeting extends HiddenVolumeStorage {
  _HeldGreeting(super.open) : super.async();
  bool hold = false, holdPreparation = false;
  final entered = Completer<void>(), release = Completer<void>();
  String? greetingId;

  @override
  Future<ContactStatus> prepareContactRequest(
    NodeId peer, {
    bool incoming = false,
  }) async {
    final status = await super.prepareContactRequest(peer, incoming: incoming);
    if (holdPreparation) {
      holdPreparation = false;
      entered.complete();
      await release.future;
    }
    return status;
  }

  @override
  Future<Message> appendMessage(Message message) async {
    final saved = await super.appendMessage(message);
    if (hold) {
      hold = false;
      greetingId = saved.id;
      entered.complete();
      await release.future;
    }
    return saved;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
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

Future<(_HeldGreeting, _Wire, MessagingService)> _fixture(
  bool native, {
  FakeKvLogStore? log,
}) async {
  Directory? dir;
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    dir = await Directory.systemTemp.createTemp('xveil-initial-request-');
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
    final kv = log ?? FakeKvLogStore();
    open = ({required password, required bool create}) async =>
        SyncWrappedAsyncKvLogStore(kv);
  }
  final storage = _HeldGreeting(open), wire = _Wire();
  final service = MessagingService(wire, storage);
  addTearDown(() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await service.dispose();
    await wire.dispose();
    await storage.close();
    await dir?.delete(recursive: true);
  });
  expect(
    await storage.open(password: 'fixture', createIfMissing: true),
    isTrue,
  );
  return (storage, wire, service);
}

void main() {
  for (final fault in ['before', 'after']) {
    test('initial admission does not hide storage failure: $fault', () async {
      final kv = _FaultStore();
      final (storage, wire, service) = await _fixture(false, log: kv);
      final peer = _id(2);
      kv.fault = fault;
      await expectLater(
        service.submitContactRequest(peer, 'recoverable greeting'),
        throwsStateError,
      );
      expect(wire.sent, isEmpty);
      expect(
        await storage.pendingOutboxFrames(),
        hasLength(fault == 'before' ? 0 : 1),
      );
      final greeting = (await storage.loadMessages(peer.hex)).single;
      await service.resendRequest(peer);
      final recovered = (await storage.pendingOutboxFrames()).single;
      expect(WireEnvelope.decode(recovered.wire).id, greeting.id);
      expect(
        wire.sent.where(
          (e) => e.kind == WireKind.request && e.id == greeting.id,
        ),
        hasLength(1),
      );
    });
  }
  for (final native in [false, true]) {
    for (final empty in [false, true]) {
      for (final decision in ['accept', 'block', 'cancel', 'replace']) {
        test(
          'initial request does not outlive $decision native=$native empty=$empty',
          () async {
            final (storage, wire, service) = await _fixture(native);
            final peer = _id(2);
            storage.hold = !empty;
            storage.holdPreparation = empty;
            final sending = service.submitContactRequest(
              peer,
              empty ? '' : 'obsolete greeting',
            );
            await storage.entered.future;
            try {
              switch (decision) {
                case 'accept':
                  await service.acceptContact(peer);
                case 'block':
                  await service.blockContact(peer);
                case 'cancel' || 'replace':
                  expect(await service.cancelRequest(peer), isTrue);
                  if (decision == 'replace') {
                    expect(
                      (await service.submitContactRequest(
                        peer,
                        'fresh greeting',
                      )).admitted,
                      isTrue,
                    );
                  }
              }
              wire.sent.clear();
              storage.release.complete();
              final result = await sending;
              expect(
                (await storage.pendingOutboxFrames()).where(
                  (f) =>
                      f.frameId.startsWith('request:') &&
                      WireEnvelope.decode(f.wire).body != 'fresh greeting',
                ),
                isEmpty,
                reason:
                    'a retired request must not reappear in the durable queue',
              );
              expect(
                wire.sent.where((e) => e.kind == WireKind.request),
                isEmpty,
              );
              expect(result, ContactRequestSubmission.refused);
              final status = (await storage.getContact(peer))?.status;
              expect(status, switch (decision) {
                'accept' => ContactStatus.accepted,
                'block' => ContactStatus.blocked,
                'replace' => ContactStatus.pendingOutgoing,
                _ => null,
              });
              if (decision == 'replace') {
                final current = (await storage.pendingOutboxFrames()).where(
                  (f) => f.frameId.startsWith('request:'),
                );
                expect(current, hasLength(1));
                expect(
                  WireEnvelope.decode(current.single.wire).body,
                  'fresh greeting',
                );
              }
            } finally {
              if (!storage.release.isCompleted) storage.release.complete();
              await sending;
            }
          },
          skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
        );
      }
    }

    for (final empty in [false, true]) {
      for (final crossed in [false, true]) {
        test(
          'current greeting remains admitted native=$native empty=$empty crossed=$crossed',
          () async {
            final (storage, wire, service) = await _fixture(native);
            final peer = _id(2);
            storage.hold = !empty;
            storage.holdPreparation = empty;
            final sending = service.submitContactRequest(
              peer,
              empty ? '' : 'current greeting',
            );
            await storage.entered.future;
            try {
              if (crossed) {
                await service.deliverInbound(
                  InboundMessage(
                    src: peer,
                    payload: const WireEnvelope.request(
                      'crossed greeting',
                      id: 'crossed',
                    ).encode(),
                    provenance: SenderProvenance.sessionPeer,
                  ),
                );
              }
              storage.release.complete();
              expect((await sending).admitted, isTrue);
              final frames = (await storage.pendingOutboxFrames()).where(
                (f) => f.frameId.startsWith('request:'),
              );
              expect(frames, hasLength(1));
              final request = WireEnvelope.decode(frames.single.wire);
              expect(request.body, empty ? '' : 'current greeting');
              expect(
                wire.sent.where(
                  (e) => e.kind == WireKind.request && e.id == request.id,
                ),
                hasLength(1),
              );
              if (!empty) {
                final greeting = await storage.loadMessageById(
                  peer.hex,
                  request.id!,
                );
                expect(greeting, isNotNull);
                expect(request.seq, greeting!.seq);
                expect(
                  request.sentAtMs,
                  greeting.timestamp.millisecondsSinceEpoch,
                );
              }
              expect(
                (await storage.getContact(peer))!.hasOutgoingRequest,
                isTrue,
              );
              expect(
                (await storage.getContact(peer))!.status,
                crossed
                    ? ContactStatus.pendingIncoming
                    : ContactStatus.pendingOutgoing,
              );
            } finally {
              if (!storage.release.isCompleted) storage.release.complete();
              await sending;
            }
          },
          skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
        );
      }
    }

    test(
      'durable block without service notice still rejects admission native=$native',
      () async {
        final (storage, wire, service) = await _fixture(native);
        final peer = _id(2);
        storage.hold = true;
        final sending = service.submitContactRequest(peer, 'not admitted');
        await storage.entered.future;
        try {
          await storage.setContactStatus(peer, ContactStatus.blocked);
          storage.release.complete();
          expect(await sending, ContactRequestSubmission.refused);
          expect(await storage.pendingOutboxFrames(), isEmpty);
          expect(wire.sent.where((e) => e.kind == WireKind.request), isEmpty);
        } finally {
          if (!storage.release.isCompleted) storage.release.complete();
          await sending;
        }
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );

    test(
      'erased greeting does not become an empty request native=$native',
      () async {
        final (storage, wire, service) = await _fixture(native);
        final peer = _id(2);
        storage.hold = true;
        final sending = service.submitContactRequest(peer, 'erase me');
        await storage.entered.future;
        try {
          await storage.deleteMessage(peer.hex, storage.greetingId!);
          storage.release.complete();
          expect(await sending, ContactRequestSubmission.refused);
          expect(await storage.pendingOutboxFrames(), isEmpty);
          expect(wire.sent.where((e) => e.kind == WireKind.request), isEmpty);
        } finally {
          if (!storage.release.isCompleted) storage.release.complete();
          await sending;
        }
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
    for (final action in ['another greeting', 'unrelated block', 'close']) {
      test(
        'initial lifetime control: $action native=$native',
        () async {
          final (storage, wire, service) = await _fixture(native);
          final peer = _id(2);
          storage.hold = true;
          final sending = service.submitContactRequest(peer, 'first greeting');
          await storage.entered.future;
          Future<void>? closing;
          try {
            switch (action) {
              case 'another greeting':
                expect(
                  (await service.submitContactRequest(
                    peer,
                    'second greeting',
                  )).admitted,
                  isTrue,
                );
              case 'unrelated block':
                await service.blockContact(_id(3));
              case 'close':
                closing = service.dispose();
            }
            storage.release.complete();
            expect((await sending).admitted, action != 'close');
            await closing;
            final frames = (await storage.pendingOutboxFrames()).where(
              (f) => f.frameId.startsWith('request:'),
            );
            expect(
              frames,
              hasLength(switch (action) {
                'close' => 0,
                'another greeting' => 2,
                _ => 1,
              }),
            );
            expect(
              wire.sent.where(
                (e) => e.kind == WireKind.request && e.id == storage.greetingId,
              ),
              hasLength(action == 'close' ? 0 : 1),
            );
          } finally {
            if (!storage.release.isCompleted) storage.release.complete();
            await sending;
            await closing;
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
  }
}
