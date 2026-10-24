import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart' show MessageDeletionIntent;
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/clear_policy.dart';
import 'package:xveil/domain/clear_request.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List.fromList(List.filled(32, n)));

class _Link extends LoopbackTransport {
  _Link({NodeId? self}) : super(localNodeId: self ?? _id(1));
  final acks = <String>[];
  Future<void> Function(Uint8List payload)? forward;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    if (frame.kind == WireKind.ack) acks.add(frame.id!);
    await forward?.call(payload);
  }
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  String? fail;
  String? held;
  final entered = Completer<void>(), release = Completer<void>();
  int scrubs = 0;
  Future<void> before(String operation) async {
    if (held == operation) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    if (fail == operation) throw StateError('injected storage refusal');
  }

  @override
  Future<int?> editMessage(
    String conversationId,
    String id,
    String body, {
    int? seq,
    List<InlineCustomEmoji> customEmoji = const [],
  }) async {
    await before('edit');
    return super.editMessage(
      conversationId,
      id,
      body,
      seq: seq,
      customEmoji: customEmoji,
    );
  }

  @override
  Future<void> deleteMessage(
    String conversationId,
    String id, {
    MessageDeletionIntent? intent,
  }) async {
    await before('delete');
    await super.deleteMessage(conversationId, id, intent: intent);
  }

  @override
  Future<void> scrubDeleted() async {
    await before('scrub');
    scrubs++;
    await super.scrubDeleted();
  }

  @override
  Future<void> putSetting(String key, String value) async {
    if (key == kPendingClearRequestsKey) await before('ask');
    await super.putSetting(key, value);
  }

  @override
  Future<void> applyRemoteClear(
    NodeId peer,
    String author,
    int seq,
    Map<String, int> watermark, {
    required String selfHex,
    int? ownClearAtMs,
    bool fromOwnDevice = false,
  }) async {
    await before('clear');
    await super.applyRemoteClear(
      peer,
      author,
      seq,
      watermark,
      selfHex: selfHex,
      ownClearAtMs: ownClearAtMs,
      fromOwnDevice: fromOwnDevice,
    );
  }
}

void main() {
  final peer = _id(2);
  late FakeHvContainer backing;
  late _Storage storage;
  late _Link link;
  late MessagingService service;
  Future<void> open() async {
    storage = _Storage(backing.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    link = _Link();
    service = MessagingService(link, storage);
  }

  Future<void> receive(WireEnvelope frame, {String? fid}) =>
      service.deliverInbound(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: (fid == null ? frame : frame.withFrameId(fid)).encode(),
        ),
      );
  Future<void> target({
    MessageDirection direction = MessageDirection.incoming,
  }) => storage.appendMessage(
    Message(
      id: 'target',
      conversationId: peer.hex,
      direction: direction,
      body: 'original',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      author: direction == MessageDirection.incoming ? peer.hex : _id(1).hex,
      seq: 1,
    ),
  );
  Future<String?> body() async =>
      (await storage.loadMessageById(peer.hex, 'target'))?.body;
  WireEnvelope frame(String kind) => switch (kind) {
    'edit' => const WireEnvelope.edit('target', 'edited', seq: 2),
    'delete' => const WireEnvelope.del('target'),
    _ => WireEnvelope.clear(jsonEncode({peer.hex: 1}), seq: 2),
  };
  Future<void> restart() async {
    await service.dispose();
    await storage.close();
    await open();
  }

  setUp(() async {
    backing = FakeHvContainer();
    await open();
    await storage.upsertContact(
      Contact(
        nodeId: peer,
        status: ContactStatus.accepted,
        clearPolicy: ClearRequestPolicy.anyone,
      ),
    );
  });
  tearDown(() async {
    await service.dispose();
    await storage.close();
  });

  for (final kind in ['edit', 'delete', 'clear']) {
    test('$kind ACK waits until storage completes', () async {
      await target();
      storage.held = kind;
      final pending = receive(frame(kind), fid: 'fixture-$kind');
      try {
        await storage.entered.future;
        expect(link.acks, isNot(contains('fixture-$kind')));
      } finally {
        storage.release.complete();
        await pending;
      }
      expect(await body(), kind == 'edit' ? 'edited' : isNull);
      expect(link.acks, contains('fixture-$kind'));
    });
    test('$kind write failure permits retry of the same frame', () async {
      await target();
      storage.fail = kind;
      await receive(frame(kind), fid: 'fixture-$kind');
      expect(await body(), 'original');
      expect(link.acks, isNot(contains('fixture-$kind')));
      storage.fail = null;
      await receive(frame(kind), fid: 'fixture-$kind');
      expect(await body(), kind == 'edit' ? 'edited' : isNull);
      expect(link.acks, contains('fixture-$kind'));
    });
  }

  test(
    'delete retries physical scrub after tombstone commit and restart',
    () async {
      await target();
      storage.fail = 'scrub';
      await receive(frame('delete'), fid: 'fixture-delete');
      expect(await body(), isNull);
      expect(link.acks, isNot(contains('fixture-delete')));
      await restart();
      await receive(frame('delete'), fid: 'fixture-delete');
      expect(storage.scrubs, 1);
      expect(link.acks, contains('fixture-delete'));
    },
  );

  for (final kind in ['edit', 'delete']) {
    test('$kind before target stays unACKed across receiver restart', () async {
      await receive(frame(kind), fid: 'fixture-$kind');
      expect(link.acks, isNot(contains('fixture-$kind')));
      await restart();
      await receive(
        const WireEnvelope.message('original', id: 'target', seq: 1),
      );
      await receive(frame(kind), fid: 'fixture-$kind');
      expect(await body(), kind == 'edit' ? 'edited' : isNull);
      expect(link.acks, contains('fixture-$kind'));
    });
    test(
      'buffered peer $kind cannot mutate our outgoing sibling mirror',
      () async {
        await receive(frame(kind), fid: 'fixture-$kind');
        await service.applyMirroredMessage(
          peer: peer,
          msgId: 'target',
          direction: MessageDirection.outgoing,
          body: 'my own message',
          tsMs: 1000,
        );
        expect(await body(), 'my own message');
      },
    );
  }

  test(
    'completed tombstone does not scrub again under a fresh frame ID',
    () async {
      await target();
      await receive(frame('delete'), fid: 'fixture-first-delete');
      expect(storage.scrubs, 1);
      await receive(frame('delete'), fid: 'fixture-second-delete');
      expect(storage.scrubs, 1);
      expect(
        link.acks,
        containsAll(['fixture-first-delete', 'fixture-second-delete']),
      );
    },
  );

  for (final kind in ['edit', 'delete']) {
    test(
      '$kind sender outbox survives both restarts until the target arrives',
      () async {
        final senderBacking = FakeHvContainer();
        late HiddenVolumeStorage senderStorage;
        late MessagingService sender;
        late _Link senderLink;
        var now = DateTime.fromMillisecondsSinceEpoch(100000);
        Future<void> openSender() async {
          senderStorage = senderBacking.storage();
          await senderStorage.open(
            password: 'sender-fixture',
            createIfMissing: true,
          );
          senderLink = _Link(self: peer);
          sender = MessagingService(senderLink, senderStorage, now: () => now);
        }

        void connect() {
          senderLink.forward = (payload) => service.deliverInbound(
            InboundMessage(
              src: peer,
              payload: payload,
              provenance: SenderProvenance.sessionPeer,
            ),
          );
          link.forward = (payload) => sender.deliverInbound(
            InboundMessage(
              src: _id(1),
              payload: payload,
              provenance: SenderProvenance.sessionPeer,
            ),
          );
        }

        await openSender();
        addTearDown(() async {
          await sender.dispose();
          await senderStorage.close();
        });
        await senderStorage.upsertContact(
          Contact(nodeId: _id(1), status: ContactStatus.accepted),
        );
        await senderStorage.appendMessage(
          Message(
            id: 'target',
            conversationId: _id(1).hex,
            direction: MessageDirection.outgoing,
            body: 'original',
            timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
            author: peer.hex,
            seq: 1,
          ),
        );
        connect();
        if (kind == 'edit') {
          await sender.editOwnMessage('target', 'edited');
        } else {
          await sender.deleteForEveryone('target');
        }
        final queued = await senderStorage.pendingOutboxFrames();
        expect(
          queued,
          hasLength(1),
          reason: 'an in-RAM pending op is not durable receipt',
        );
        final fid = queued.single.frameId;
        expect(link.acks, isNot(contains(fid)));

        await restart();
        await sender.dispose();
        await senderStorage.close();
        await openSender();
        connect();
        expect(await senderStorage.pendingOutboxFrames(), hasLength(1));
        await receive(
          const WireEnvelope.message('original', id: 'target', seq: 1),
        );
        now = now.add(const Duration(minutes: 1));
        await sender.flushOutbox();
        expect(await body(), kind == 'edit' ? 'edited' : isNull);
        expect(await senderStorage.pendingOutboxFrames(), isEmpty);
        expect(link.acks, contains(fid));
      },
    );
  }

  for (final peerFirst in [true, false]) {
    test(
      'peer delete cannot replace a pending device edit (peerFirst=$peerFirst)',
      () async {
        if (peerFirst) await receive(frame('delete'), fid: 'fixture-delete');
        await service.applyMirroredEdit(
          peer: peer,
          msgId: 'target',
          body: 'my edit',
        );
        if (!peerFirst) await receive(frame('delete'), fid: 'fixture-delete');
        await service.applyMirroredMessage(
          peer: peer,
          msgId: 'target',
          direction: MessageDirection.outgoing,
          body: 'my message',
          tsMs: 1000,
        );
        expect(await body(), 'my edit');
      },
    );
  }

  test(
    'declined delete and clear are ACKed without revealing the policy',
    () async {
      await target();
      await storage.upsertContact(
        Contact(
          nodeId: peer,
          status: ContactStatus.accepted,
          allowPeerDelete: false,
          clearPolicy: ClearRequestPolicy.never,
        ),
      );
      await receive(frame('delete'), fid: 'fixture-delete');
      await receive(frame('clear'), fid: 'fixture-clear');
      expect(await body(), 'original');
      expect(link.acks, containsAll(['fixture-delete', 'fixture-clear']));
    },
  );

  for (final hold in [true, false]) {
    test(
      'ask-before-clear ACK follows request persistence (hold=$hold)',
      () async {
        await target();
        await storage.upsertContact(
          Contact(
            nodeId: peer,
            status: ContactStatus.accepted,
            clearPolicy: ClearRequestPolicy.ask,
          ),
        );
        if (hold) {
          storage.held = 'ask';
          final pending = receive(frame('clear'), fid: 'fixture-clear');
          try {
            await storage.entered.future;
            expect(link.acks, isNot(contains('fixture-clear')));
          } finally {
            storage.release.complete();
            await pending;
          }
        } else {
          storage.fail = 'ask';
          await receive(frame('clear'), fid: 'fixture-clear');
          expect(link.acks, isNot(contains('fixture-clear')));
          expect(await service.pendingClearRequests(), isEmpty);
          storage.fail = null;
          await receive(frame('clear'), fid: 'fixture-clear');
        }
        expect(await body(), 'original');
        expect(await service.pendingClearRequests(), hasLength(1));
        expect(link.acks, contains('fixture-clear'));
      },
    );
  }
}
