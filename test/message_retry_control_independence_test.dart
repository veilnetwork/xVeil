import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int tag) => NodeId(Uint8List(32)..fillRange(0, 32, tag));

class _Storage extends HiddenVolumeStorage {
  _Storage()
    : super(({required password, required create}) => FakeKvLogStore());
  Completer<void>? holdControlRead, controlReadEntered;
  Future<void> Function()? beforeConversations;
  @override
  Future<List<OutboxFrame>> pendingOutboxFrames() async {
    controlReadEntered?.complete();
    controlReadEntered = null;
    await holdControlRead?.future;
    return super.pendingOutboxFrames();
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    await beforeConversations?.call();
    return super.loadConversations();
  }
}

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final controlEntered = Completer<void>(), releaseControl = Completer<void>();
  final sent = <WireEnvelope>[];
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Future<void> send(
    NodeId peer,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(bytes);
    sent.add(frame);
    if (frame.frameId == 'edit:held') {
      if (!controlEntered.isCompleted) controlEntered.complete();
      await releaseControl.future;
    }
  }

  @override
  Future<void> sendWithReply(NodeId peer, Uint8List bytes) => send(peer, bytes);
  @override
  Future<void> sendReply(int replyId, Uint8List bytes) async {}
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() => inbound.close();
}

void main() {
  late _Storage storage;
  late _Transport transport;
  late MessagingService service;
  final runs = <Future<void>>[];
  setUp(() async {
    storage = _Storage();
    await storage.open(password: 'fixture', createIfMissing: true);
    transport = _Transport();
    service = MessagingService(transport, storage);
    for (final peer in [_id(2), _id(3)]) {
      await storage.upsertContact(Contact(nodeId: peer));
    }
    await storage.enqueueOutboxFrame(
      'edit:held',
      _id(2).hex,
      WireEnvelope.edit(
        'old-message',
        'edited',
        seq: 1,
      ).withFrameId('edit:held').encode(),
    );
    await storage.appendMessage(
      Message(
        id: 'pending-message',
        conversationId: _id(3).hex,
        direction: MessageDirection.outgoing,
        body: 'ordinary retry',
        timestamp: DateTime.now(),
        author: _id(1).hex,
        seq: 1,
      ),
    );
  });
  tearDown(() async {
    if (!transport.releaseControl.isCompleted) {
      transport.releaseControl.complete();
    }
    final held = storage.holdControlRead;
    if (held != null && !held.isCompleted) held.complete();
    await Future.wait(runs);
    runs.clear();
    await service.dispose();
    await storage.close();
  });

  test(
    'a failed conversation pass still joins the pending control job',
    () async {
      storage.beforeConversations = () async {
        await transport.controlEntered.future;
        throw StateError('conversation read failed');
      };
      var finished = false;
      Object? failure;
      final observed = service.flushOutbox().then<void>(
        (_) {
          finished = true;
        },
        onError: (Object error) {
          failure = error;
          finished = true;
        },
      );
      runs.add(observed);
      await transport.controlEntered.future;
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      transport.releaseControl.complete();
      await observed;
      expect(failure, isA<StateError>());
      expect(await storage.pendingOutboxFrames(), hasLength(1));
    },
  );

  test('media pause keeps ordinary retries paused', () async {
    service.backgroundStashPaused = true;
    await service.flushOutbox();
    expect(transport.sent.where((f) => f.kind == WireKind.message), isEmpty);
    expect(await storage.pendingOutboxFrames(), hasLength(1));
  });

  for (final phase in ['send', 'read']) {
    test('ordinary retry progresses while control $phase is held', () async {
      if (phase == 'read') {
        storage.holdControlRead = Completer<void>();
        storage.controlReadEntered = Completer<void>();
      }
      final entered = phase == 'read'
          ? storage.controlReadEntered!.future
          : transport.controlEntered.future;
      var finished = false;
      runs.add(
        service.flushOutbox().then((_) {
          finished = true;
        }),
      );
      await entered;
      // Drain ready microtasks with an event-loop barrier. The control gate
      // stays closed: progress cannot be credited to its ten-second deadline.
      await Future<void>.delayed(Duration.zero);
      expect(
        transport.sent.where((f) => f.kind == WireKind.message),
        hasLength(1),
      );
      expect(finished, isFalse, reason: 'flush still joins its control work');
    });
  }
}
