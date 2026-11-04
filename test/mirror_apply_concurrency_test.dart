import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List.fromList(List.filled(32, n)));

class _HeldAppend extends HiddenVolumeStorage {
  _HeldAppend(super.opener);
  final entered = Completer<void>(), release = Completer<void>();
  final calls = <(String, String), int>{};
  bool holdFirst = true, failFirst = false;

  @override
  Future<Message> appendMessage(Message row) async {
    final key = (row.conversationId, row.id);
    calls[key] = (calls[key] ?? 0) + 1;
    if (holdFirst) {
      holdFirst = false;
      entered.complete();
      await release.future;
      if (failFirst) throw StateError('injected append refusal');
    }
    return super.appendMessage(row);
  }
}

void main() {
  final peer = _id(2), other = _id(4);
  late FakeHvContainer backing;
  late _HeldAppend storage;
  late MessagingService service;

  setUp(() async {
    backing = FakeHvContainer();
    storage = _HeldAppend(backing.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    service = MessagingService(LoopbackTransport(localNodeId: _id(1)), storage);
    service.groupBindingsOwner = Object();
  });

  tearDown(() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await service.dispose();
    await storage.close();
  });

  Future<bool> mirror(
    NodeId to, {
    MessageStatus status = MessageStatus.delivered,
    String body = 'original',
  }) => service.applyMirroredMessage(
    peer: to,
    msgId: 'shared',
    direction: MessageDirection.outgoing,
    body: body,
    tsMs: 1000,
    status: status,
  );

  int rawPosts(NodeId to) {
    final store = backing.rawStoreFor('fixture')!;
    var count = 0;
    for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++) {
      for (final row in store.iterLogRange(namespace: ns, limit: 100)) {
        final value = jsonDecode(utf8.decode(row.payload)) as Map;
        if (value['c'] == to.hex &&
            value['id'] == 'shared' &&
            value['op'] == null) {
          count++;
        }
      }
    }
    return count;
  }

  test(
    'prepared mirror holds its key and completion until durable publication',
    () async {
      storage.holdFirst = false;
      final ready = Completer<Message>();
      final publish = Completer<PreparedMessageWrite>();
      var completed = false;
      final first = service
          .applyMirroredMessage(
            peer: peer,
            msgId: 'shared',
            direction: MessageDirection.outgoing,
            body: 'prepared',
            tsMs: 1000,
            author: other.hex,
            seq: 1,
            appendPrepared: (row) {
              ready.complete(row);
              return publish.future;
            },
          )
          .whenComplete(() {
            completed = true;
          });
      final row = await ready.future;
      final duplicate = mirror(peer);
      expect(await mirror(other), isTrue);
      expect(completed, isFalse);
      expect(await storage.loadMessageById(peer.hex, 'shared'), isNull);
      expect(storage.calls[(peer.hex, 'shared')], isNull);
      final result = await storage.appendMissingMessageBatch([
        row,
      ], beforeCommit: () async {});
      publish.complete(result!.single);
      expect(await first, isTrue);
      expect(
        await duplicate,
        isTrue,
        reason:
            'queued mirror upgrades delivery after the prepared post commits',
      );
      expect(rawPosts(peer), 1);
      expect(
        (await storage.loadMessageById(peer.hex, 'shared'))!.status,
        MessageStatus.delivered,
      );
    },
  );

  test(
    'wire winner at prepared boundary uses ordinary merge without a second post',
    () async {
      storage.holdFirst = false;
      final ready = Completer<Message>();
      final publish = Completer<PreparedMessageWrite>();
      final applying = service.applyMirroredMessage(
        peer: peer,
        msgId: 'shared',
        direction: MessageDirection.outgoing,
        body: 'stale history',
        tsMs: 1000,
        author: other.hex,
        seq: 1,
        status: MessageStatus.delivered,
        appendPrepared: (row) {
          ready.complete(row);
          return publish.future;
        },
      );
      final row = await ready.future;
      await storage.appendMessage(
        row.copyWith(body: 'wire winner', status: MessageStatus.sent),
      );
      final result = await storage.appendMissingMessageBatch([
        row,
      ], beforeCommit: () async {});
      expect(result, [PreparedMessageWrite.existing]);
      publish.complete(result!.single);
      await applying;
      final winner = (await storage.loadMessageById(peer.hex, 'shared'))!;
      expect(winner.body, 'wire winner');
      expect(winner.status, MessageStatus.delivered);
      expect(rawPosts(peer), 1);
    },
  );

  test(
    'concurrent mirrors append one durable post while another conversation progresses',
    () async {
      final first = mirror(peer);
      await storage.entered.future;
      final second = mirror(peer, body: 'duplicate must not replace the first');
      late final List<bool> results;
      late final bool visibleBeforeFirstCommit;
      try {
        expect(await mirror(other), isTrue);
        visibleBeforeFirstCommit =
            await storage.loadMessageById(peer.hex, 'shared') != null;
      } finally {
        storage.release.complete();
        results = await Future.wait([first, second]);
      }
      expect(
        rawPosts(peer),
        1,
        reason: 'the materialized view can hide duplicate journal posts',
      );
      expect(results, [true, false]);
      expect(visibleBeforeFirstCommit, isFalse);
      expect(storage.calls[(peer.hex, 'shared')], 1);
      expect(storage.calls[(other.hex, 'shared')], 1);
      expect(
        (await storage.loadMessageById(peer.hex, 'shared'))!.body,
        'original',
      );
      expect(rawPosts(other), 1);
    },
  );

  test(
    'a queued mirror still applies newer delivery evidence after the first commit',
    () async {
      final first = mirror(peer, status: MessageStatus.sent);
      await storage.entered.future;
      final second = mirror(peer);
      try {
        expect(await mirror(other), isTrue);
      } finally {
        storage.release.complete();
      }
      await Future.wait([first, second]);
      expect(
        (await storage.loadMessageById(peer.hex, 'shared'))!.status,
        MessageStatus.delivered,
      );
      expect(storage.calls[(peer.hex, 'shared')], 1);
      expect(rawPosts(peer), 1);
    },
  );

  test(
    'a failed first append does not poison a waiting mirror retry',
    () async {
      storage.failFirst = true;
      final firstError = expectLater(mirror(peer), throwsStateError);
      await storage.entered.future;
      final retry = mirror(peer);
      try {
        expect(await mirror(other), isTrue);
      } finally {
        storage.release.complete();
      }
      await firstError;
      expect(await retry, isTrue);
      expect(rawPosts(peer), 1);
      expect(
        (await storage.loadMessageById(peer.hex, 'shared'))!.body,
        'original',
      );
    },
  );

  for (final closing in [false, true]) {
    test(
      'waiting mirror retains admission lifetime, closing=$closing',
      () async {
        storage.failFirst = true;
        final firstError = expectLater(mirror(peer), throwsStateError);
        await storage.entered.future;
        final waiting = mirror(peer);
        final stopped = closing ? service.dispose() : Future<void>.value();
        if (!closing) service.groupBindingsOwner = Object();
        storage.release.complete();
        await firstError;
        expect(await waiting, isFalse);
        await stopped;
        expect(rawPosts(peer), 0);
      },
    );
  }
}
