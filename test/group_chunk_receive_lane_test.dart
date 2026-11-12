import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Capture extends LoopbackTransport {
  _Capture(int id) : super(localNodeId: _id(id));
  final sent = <Uint8List>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(Uint8List.fromList(payload));
  }
}

Future<List<Uint8List>> _chunks(String body) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'fixture', createIfMissing: true);
  final transport = _Capture(2);
  final sender = MessagingService(transport, storage);
  try {
    await sender.sendGroupSnapshot(_id(1), 'ab' * 32, body);
    expect(transport.sent.length, greaterThan(1));
    expect(
      transport.sent
          .map(WireEnvelope.decode)
          .every((e) => e.kind == WireKind.groupEntryChunk),
      isTrue,
    );
    return transport.sent;
  } finally {
    await sender.dispose();
    await transport.dispose();
    await storage.close();
  }
}

void main() {
  test(
    'a stranger reassembly lease cannot ACK a rejected complete snapshot',
    () async {
      final body = jsonEncode({'fixture': 'x' * 7000});
      final chunks = await _chunks(body);
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      final link = _Capture(1);
      final receiver = MessagingService(link, storage);
      var lease = true;
      var accepted = false;
      var applies = 0;
      receiver.allowStrangerGroupSync = (_, _) async => false;
      receiver.allowStrangerGroupReassembly = (peer, group) async =>
          lease && peer == _id(2) && group == 'ab' * 32;
      receiver.onGroupEntryFromStranger = (_, json) async {
        expect(json, body);
        applies++;
        return accepted;
      };
      Future<void> deliver() async {
        for (final chunk in chunks) {
          await receiver.deliverInbound(
            InboundMessage(
              src: _id(2),
              provenance: SenderProvenance.sessionPeer,
              payload: chunk,
            ),
          );
        }
      }

      try {
        await deliver();
        expect(applies, 1);
        expect(
          link.sent,
          isEmpty,
          reason: 'partial RAM is not a durable apply',
        );
        lease = false;
        await deliver();
        expect(
          applies,
          1,
          reason: 'revoked consent cannot allocate another assembly',
        );
        expect(link.sent, isEmpty);
        lease = true;
        accepted = true;
        await deliver();
        expect(applies, 2);
        expect(
          link.sent
              .map(WireEnvelope.decode)
              .where((e) => e.kind == WireKind.ack),
          hasLength(1),
        );
      } finally {
        await receiver.dispose();
        await link.dispose();
        await storage.close();
      }
    },
  );

  test(
    'chunked catch-up progresses while an earlier ordinary apply is held',
    () async {
      final body = jsonEncode({'history': 'x' * 7000});
      final chunks = await _chunks(body);
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      await storage.upsertContact(
        Contact(nodeId: _id(2), status: ContactStatus.accepted),
      );
      final link = _Capture(1);
      final receiver = MessagingService(link, storage);
      final entered = Completer<void>(), release = Completer<void>();
      var firstDone = false;
      receiver.onGroupEntry = (_, json) async {
        if (json == '{"old":true}') {
          entered.complete();
          await release.future;
        } else {
          expect(json, body);
        }
        return true;
      };
      InboundMessage incoming(Uint8List payload) => InboundMessage(
        src: _id(2),
        provenance: SenderProvenance.sessionPeer,
        payload: payload,
      );
      final first = receiver
          .deliverInbound(
            incoming(
              WireEnvelope.groupEntry(
                '{"old":true}',
              ).withFrameId('old').encode(),
            ),
          )
          .then((_) => firstDone = true);
      await entered.future;
      try {
        final transfer = Future.wait(
          chunks.map((frame) => receiver.deliverInbound(incoming(frame))),
        );
        // This is a gate-based liveness assertion, not a latency benchmark.
        await transfer.timeout(const Duration(seconds: 2));
        expect(firstDone, isFalse);
        final acks = link.sent
            .map(WireEnvelope.decode)
            .where((e) => e.kind == WireKind.ack)
            .toList();
        expect(acks, hasLength(1));
        expect(acks.single.id, startsWith('grpa:'));
      } finally {
        release.complete();
        await first;
        await receiver.dispose();
        await link.dispose();
        await storage.close();
      }
    },
  );
  for (final disposeWhileHeld in [false, true]) {
    test(
      'held chunk apply keeps its ACK boundary and joins shutdown (dispose=$disposeWhileHeld)',
      () async {
        final body = jsonEncode({'history': 'x' * 7000});
        final chunks = await _chunks(body);
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'fixture', createIfMissing: true);
        await storage.upsertContact(
          Contact(nodeId: _id(2), status: ContactStatus.accepted),
        );
        final link = _Capture(1);
        final receiver = MessagingService(link, storage);
        final entered = Completer<void>(), release = Completer<void>();
        receiver.onGroupEntry = (_, json) async {
          expect(json, body);
          entered.complete();
          await release.future;
          return true;
        };
        InboundMessage incoming(Uint8List payload) => InboundMessage(
          src: _id(2),
          provenance: SenderProvenance.sessionPeer,
          payload: payload,
        );
        final transfer = Future.wait(
          chunks.map((frame) => receiver.deliverInbound(incoming(frame))),
        );
        await entered.future;
        try {
          expect(link.sent, isEmpty, reason: 'no ACK before durable apply');
          if (disposeWhileHeld) {
            var closed = false;
            final close = receiver.dispose().then((_) => closed = true);
            await Future<void>.delayed(Duration.zero);
            expect(
              closed,
              isFalse,
              reason: 'shutdown must join the fragment lane',
            );
            release.complete();
            await Future.wait([transfer, close]);
            expect(
              link.sent,
              isEmpty,
              reason: 'a closed binding cannot mint an ACK',
            );
          } else {
            await receiver
                .deliverInbound(
                  incoming(
                    WireEnvelope.message(
                      'independent chat',
                      id: 'chat',
                      seq: 1,
                    ).encode(),
                  ),
                )
                .timeout(const Duration(seconds: 2));
            expect(
              (await storage.loadMessages(_id(2).hex)).single.body,
              'independent chat',
            );
            expect(link.sent.map(WireEnvelope.decode).map((e) => e.id), [
              'chat',
            ]);
            release.complete();
            await transfer;
            final acks = link.sent.map(WireEnvelope.decode).toList();
            expect(acks, hasLength(2));
            expect(acks.last.id, startsWith('grpa:'));
          }
        } finally {
          if (!release.isCompleted) release.complete();
          await transfer;
          await receiver.dispose();
          await link.dispose();
          await storage.close();
        }
      },
    );
  }
}
