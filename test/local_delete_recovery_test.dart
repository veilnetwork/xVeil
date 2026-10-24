import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/message_deletion.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int v) => NodeId(Uint8List.fromList(List.filled(32, v)));

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
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

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  String? fail;
  int scrubCalls = 0;

  @override
  Future<void> scrubDeleted() async {
    scrubCalls++;
    if (fail == 'scrub') throw StateError('fixture scrub refusal');
    await super.scrubDeleted();
  }

  @override
  Future<void> enqueueOutboxFrame(
    String id,
    String peer,
    Uint8List wire,
  ) async {
    if (fail == 'enqueue') throw StateError('fixture outbox refusal');
    await super.enqueueOutboxFrame(id, peer, wire);
  }

  @override
  Future<void> completeMessageDeletion(
    String conversationId,
    String messageId, {
    bool mirror = false,
    bool peer = false,
    bool serving = false,
  }) async {
    if (fail == 'completion') throw StateError('fixture completion refusal');
    await super.completeMessageDeletion(
      conversationId,
      messageId,
      mirror: mirror,
      peer: peer,
      serving: serving,
    );
  }

  @override
  Future<void> putSetting(String key, String value) async {
    if (fail == 'serving' && key.startsWith('served:')) {
      throw StateError('fixture serving cleanup refusal');
    }
    await super.putSetting(key, value);
  }
}

void main() {
  final peer = _id(2);
  late FakeHvContainer backing;
  late _Storage storage;
  late MessagingService service;
  Future<void> open() async {
    storage = _Storage(backing.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    service = MessagingService(_Link(), storage);
  }

  Future<void> target({
    String id = 'target',
    MessageDirection direction = MessageDirection.outgoing,
    String? contentId,
  }) async {
    await storage.upsertContact(Contact(nodeId: peer));
    await storage.appendMessage(
      Message(
        id: id,
        conversationId: peer.hex,
        direction: direction,
        body: 'private body to erase',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        author: _id(1).hex,
        seq: 1,
        fileContentId: contentId,
      ),
    );
  }

  Future<void> restart() async {
    await service.dispose();
    await storage.close();
    await open();
  }

  Future<void> drainRepair() async {
    // A drained page resets its cursor on the following pass. These calls
    // explicitly drive the production retry, without waiting for its timer.
    for (var i = 0; i < 3; i++) {
      await service.retryPendingMessageDeletions();
    }
  }

  setUp(() async {
    backing = FakeHvContainer();
    await open();
    await target();
  });
  tearDown(() async {
    await service.dispose();
    await storage.close();
  });

  test(
    'local deletion retries publication after its message has disappeared',
    () async {
      var fail = true, calls = 0;
      service.onMessageDeleted = (_, _) async {
        calls++;
        if (fail) throw StateError('injected device journal refusal');
      };
      await expectLater(
        service.deleteMessageLocally('target'),
        throwsStateError,
      );
      expect(await storage.loadMessageById(peer.hex, 'target'), isNull);
      fail = false;
      await service.deleteMessageLocally('target');
      expect(calls, greaterThanOrEqualTo(2));
    },
  );

  test(
    'unsend is durably queued even when own-device publication fails',
    () async {
      service.onMessageDeleted = (_, _) async =>
          throw StateError('injected device journal refusal');
      await expectLater(service.deleteForEveryone('target'), throwsStateError);
      expect(await storage.loadMessageById(peer.hex, 'target'), isNull);
      expect(
        (await storage.pendingOutboxFrames()).where(
          (f) => f.frameId == 'del:target',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'restart finishes publication without the removed source row or another click',
    () async {
      service.onMessageDeleted = (_, _) async =>
          throw StateError('injected device journal refusal');
      await expectLater(
        service.deleteMessageLocally('target'),
        throwsStateError,
      );
      await service.dispose();
      await storage.close();
      await open();
      final published = Completer<void>();
      service.onMessageDeleted = (p, id) async {
        expect(p, peer);
        expect(id, 'target');
        if (!published.isCompleted) published.complete();
      };
      service.start();
      await published.future.timeout(const Duration(seconds: 1));
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );

  test(
    'scrub failure after commit survives restart without the source',
    () async {
      var publications = 0;
      service.onMessageDeleted = (_, _) async => publications++;
      storage.fail = 'scrub';
      await expectLater(service.deleteForEveryone('target'), throwsStateError);
      expect(publications, 0);
      await restart();
      service.onMessageDeleted = (_, _) async => publications++;
      await drainRepair();
      expect(publications, 1);
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(await storage.pendingMessageDeletions(), isEmpty);
      expect(await storage.pendingOutboxFrames(), hasLength(1));
    },
  );

  test('outbox refusal preserves peer duty independently of mirror', () async {
    var publications = 0;
    service.onMessageDeleted = (_, _) async => publications++;
    storage.fail = 'enqueue';
    await expectLater(service.deleteForEveryone('target'), throwsStateError);
    expect(publications, 1);
    final pending = (await storage.pendingMessageDeletions()).single;
    expect(pending.peerPending, isTrue);
    expect(pending.mirrorPending, isFalse);
    await restart();
    // No publisher is needed to hand the remaining peer duty to the outbox.
    await drainRepair();
    expect(await storage.pendingMessageDeletions(), isEmpty);
    expect(await storage.pendingOutboxFrames(), hasLength(1));
  });

  test('failed completion replays an idempotent durable handoff', () async {
    service.onMessageDeleted = (_, _) async {};
    storage.fail = 'completion';
    await expectLater(service.deleteForEveryone('target'), throwsStateError);
    expect(await storage.pendingOutboxFrames(), hasLength(1));
    await restart();
    service.onMessageDeleted = (_, _) async {};
    await drainRepair();
    expect(await storage.pendingMessageDeletions(), isEmpty);
    expect(await storage.pendingOutboxFrames(), hasLength(1));
  });

  test('held mirror cannot prevent the peer handoff', () async {
    final entered = Completer<void>(), release = Completer<void>();
    service.onMessageDeleted = (_, _) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final deleting = service.deleteForEveryone('target');
    try {
      await entered.future.timeout(const Duration(seconds: 1));
      expect(await storage.pendingOutboxFrames(), hasLength(1));
      final pending = (await storage.pendingMessageDeletions()).single;
      expect(pending.peerPending, isFalse);
      expect(pending.mirrorPending, isTrue);
    } finally {
      release.complete();
      await deleting;
    }
  });

  test('replacement publisher inherits an unfinished binding duty', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var replacementCalls = 0;
    service.onMessageDeleted = (_, _) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final deleting = service.deleteMessageLocally('target');
    try {
      await entered.future.timeout(const Duration(seconds: 1));
      service.onMessageDeleted = (_, _) async => replacementCalls++;
    } finally {
      release.complete();
      await deleting;
    }
    await drainRepair();
    expect(replacementCalls, 1);
    expect(await storage.pendingMessageDeletions(), isEmpty);
  });

  test('attaching a publisher recovers deletion made while unbound', () async {
    await service.deleteMessageLocally('target');
    expect(await storage.pendingMessageDeletions(), hasLength(1));
    var publications = 0;
    service.onMessageDeleted = (_, _) async => publications++;
    await drainRepair();
    expect(publications, 1);
    expect(await storage.pendingMessageDeletions(), isEmpty);
  });

  test(
    'incoming and mirrored deletes never manufacture a local intent',
    () async {
      await storage.deleteMessage(peer.hex, 'target');
      await target(id: 'incoming', direction: MessageDirection.incoming);
      await service.deleteForEveryone('incoming');
      await service.deleteForEveryone('unknown');
      await service.applyMirroredDelete(peer: peer, msgId: 'incoming');
      await drainRepair();
      expect(await storage.pendingMessageDeletions(), isEmpty);
      expect(await storage.pendingOutboxFrames(), isEmpty);
    },
  );

  test('failed first page does not starve later deletion decisions', () async {
    await storage.deleteMessage(peer.hex, 'target');
    for (var i = 0; i < 66; i++) {
      await target(id: 'pending-$i');
      await storage.deleteMessage(
        peer.hex,
        'pending-$i',
        intent: MessageDeletionIntent.devices,
      );
    }
    final seen = <String>{};
    service.onMessageDeleted = (_, id) async {
      seen.add(id);
      if (id != 'pending-65') throw StateError('fixture journal refusal');
    };
    await drainRepair();
    expect(seen, hasLength(66));
    expect(await storage.pendingMessageDeletions(limit: 256), hasLength(65));
    expect(
      (await storage.pendingMessageDeletions(
        limit: 256,
      )).any((p) => p.messageId == 'pending-65'),
      isFalse,
    );
  });

  test(
    'dispose joins an already authorized deletion before returning',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      service.onMessageDeleted = (_, _) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final deleting = service.deleteMessageLocally('target');
      await entered.future.timeout(const Duration(seconds: 1));
      var disposed = false;
      final closing = service.dispose().then((_) => disposed = true);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(disposed, isFalse);
      } finally {
        release.complete();
        await deleting;
        await closing;
      }
      expect(await storage.pendingMessageDeletions(), isEmpty);
    },
  );

  test(
    'file serving cleanup failure survives restart with only recovery metadata',
    () async {
      const cid = 'fixture-cid';
      await target(contentId: cid);
      await storage.putSetting('served:$cid', 'fixture serving state');
      var publications = 0;
      service.onMessageDeleted = (_, _) async => publications++;
      storage.fail = 'serving';
      await expectLater(
        service.deleteMessageLocally('target'),
        throwsStateError,
      );
      final pending = (await storage.pendingMessageDeletions()).single;
      expect(pending.contentId, cid);
      expect(pending.mirrorPending, isFalse);
      expect(publications, 1);
      await restart();
      await drainRepair();
      expect(await storage.getSetting('served:$cid'), '');
      expect(await storage.pendingMessageDeletions(), isEmpty);
      expect(storage.scrubCalls, 1);
    },
  );

  test('deleted versions are erased and sequence slot is retained', () async {
    await storage.editMessage(
      peer.hex,
      'target',
      'private edited body',
      seq: 2,
      customEmoji: const <InlineCustomEmoji>[],
    );
    await service.deleteMessageLocally('target');
    final pending = (await storage.pendingMessageDeletions()).single;
    expect(pending.mirrorPending, isTrue);
    final raw = backing.rawStoreFor('fixture')!;
    final logs = [
      for (final ns in [
        Ns.messageLog,
        for (
          var ns = Ns.messageLogShardFirst;
          ns <= Ns.messageLogShardRetiredLast;
          ns++
        )
          ns,
      ])
        ...raw.iterLogRange(namespace: ns, limit: 100),
    ];
    final encoded = logs.map((row) => utf8.decode(row.payload)).join('\n');
    expect(encoded, isNot(contains('private body')));
    expect(encoded, isNot(contains('private edited body')));
    final tomb = logs
        .map((row) => jsonDecode(utf8.decode(row.payload)))
        .whereType<Map<String, dynamic>>()
        .singleWhere((row) => row['op'] == 'del' && row['id'] == 'target');
    expect(tomb['au'], _id(1).hex);
    expect(tomb['sq'], 1);
    expect(tomb.keys, unorderedEquals(['op', 'id', 'c', 'au', 'sq', 'dm']));
    final scrubs = storage.scrubCalls;
    service.onMessageDeleted = (_, _) async => throw StateError('fixture');
    await drainRepair();
    expect(
      storage.scrubCalls,
      scrubs,
      reason: 'failed journal retries need no new physical scrub',
    );
  });
}
