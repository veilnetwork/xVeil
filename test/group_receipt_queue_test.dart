import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  final entered = Completer<void>(), release = Completer<void>();
  final acknowledgements = <String>[];
  final destinations = <NodeId>[];
  final replies = <int>[];
  final input = StreamController<InboundMessage>.broadcast();
  bool hold = true;

  @override
  Stream<InboundMessage> messages() => input.stream;

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    if (frame.kind != WireKind.ack) return;
    if (hold && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    acknowledgements.add(frame.id!);
    destinations.add(dst);
  }

  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {
    replies.add(replyId);
    if (hold && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    acknowledgements.add(WireEnvelope.decode(payload).id!);
  }

  @override
  Future<void> dispose() async {
    await input.close();
    await super.dispose();
  }
}

class _Capture extends LoopbackTransport {
  _Capture() : super(localNodeId: _id(2));
  final frames = <Uint8List>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    frames.add(Uint8List.fromList(payload));
  }
}

Future<List<Uint8List>> _frames({required bool chunked}) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'fixture', createIfMissing: true);
  final link = _Capture();
  final service = MessagingService(link, storage);
  try {
    await service.sendGroupSnapshot(
      _id(1),
      'ab' * 32,
      jsonEncode({'fixture': chunked ? 'x' * 4500 : 'small'}),
    );
    return link.frames;
  } finally {
    await service.dispose();
    await storage.close();
    await link.dispose();
  }
}

Future<void> _until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  for (final chunked in [false, true]) {
    test(
      'a committed group ACK cannot hold later durable messages ($chunked chunked)',
      () async {
        final r = await _rig();
        final frames = await _frames(chunked: chunked);
        expect(frames.length, chunked ? greaterThan(1) : 1);
        expect(
          frames.map((w) => WireEnvelope.decode(w).kind),
          everyElement(
            chunked ? WireKind.groupEntryChunk : WireKind.groupEntry,
          ),
        );
        if (chunked) {
          final parts =
              frames
                  .map((w) => parseGroupEntryChunk(WireEnvelope.decode(w).body))
                  .toList()
                ..sort((a, b) => a.index.compareTo(b.index));
          final joined = Uint8List.fromList(
            parts.expand((p) => p.data).toList(),
          );
          expect(jsonDecode(utf8.decode(joined)), {'fixture': 'x' * 4500});
          final digest = crypto.sha256.convert([
            ...utf8.encode(
              'xveil.replication.group-snapshot.v1\u0000${'ab' * 32}\u0000',
            ),
            ...joined,
          ]).toString();
          expect(parts.first.transferId.split(':')[2], digest);
          expect(parts.every((p) => p.count == 3 && p.transferAck), isTrue);
        }
        var applied = 0;
        r.service.onGroupEntry = (_, body) async {
          await r.storage.putSetting('fixture.applied', body.length.toString());
          applied++;
          return true;
        };
        var settled = false;
        final receipts = <Future<void>>[];
        for (final wire in frames) {
          receipts.add(
            r.service.deliverInbound(
              InboundMessage(
                src: _id(2),
                provenance: SenderProvenance.sessionPeer,
                payload: wire,
              ),
            ),
          );
        }
        final first = Future.wait(receipts).then((_) {
          settled = true;
        });
        await r.link.entered.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            throw StateError(
              'group receipt was not entered; applied=$applied; captures=${frames.length}',
            );
          },
        );
        expect(await r.storage.getSetting('fixture.applied'), isNotNull);
        expect(applied, 1);
        expect(
          settled,
          isFalse,
          reason: 'explicit delivery must still join ACK settlement',
        );
        final second = r.service.deliverInbound(
          InboundMessage(
            src: _id(3),
            provenance: SenderProvenance.sessionPeer,
            payload: WireEnvelope.message(
              'later fixture',
              id: 'later',
              seq: 1,
            ).encode(),
          ),
        );
        await _until(
          () async =>
              await r.storage.loadMessageById(_id(3).hex, 'later') != null,
        );
        expect(
          await r.storage.loadMessageById(_id(3).hex, 'later'),
          isNotNull,
          reason:
              'a committed group effect must release durable dispatch before its ACK transport',
        );
        expect(r.link.acknowledgements, everyElement('later'));
        r.link.release.complete();
        await Future.wait([first, second]);
        expect(r.link.acknowledgements.length, 2);
        expect(r.link.acknowledgements, contains('later'));
      },
    );
  }

  test(
    'live group ACK waits retain no original inbound admission reservation',
    () async {
      final r = await _rig();
      r.service.onGroupEntry = (_, body) async => true;
      r.service.start();
      final wire = (await _frames(chunked: false)).single;
      r.link.input.add(
        InboundMessage(
          src: _id(2),
          provenance: SenderProvenance.sessionPeer,
          payload: wire,
        ),
      );
      await r.link.entered.future;
      await _until(() => r.service.inboundAdmission.queuedFrames == 0);
      expect(r.service.inboundAdmission.queuedFrames, 0);
      expect(r.service.inboundAdmission.queuedBytes, 0);
      expect(r.link.acknowledgements, isEmpty);
      r.link.release.complete();
    },
  );

  test('no group ACK is queued before its durable apply succeeds', () async {
    final r = await _rig();
    r.link.hold = false;
    final gate = Completer<void>();
    r.service.onGroupEntry = (_, body) async {
      await gate.future;
      throw StateError('injected commit failure');
    };
    final wire = (await _frames(chunked: false)).single;
    final receiving = _receive(r.service, wire);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(r.link.acknowledgements, isEmpty);
    gate.complete();
    await receiving;
    expect(r.link.acknowledgements, isEmpty);
    r.service.onGroupEntry = (_, body) async {
      await r.storage.putSetting('applied', 'yes');
      return true;
    };
    await _receive(r.service, wire);
    expect(r.link.acknowledgements, hasLength(1));
    expect(await r.storage.getSetting('applied'), 'yes');
  });

  test(
    'a replaced group binding discards queued ACKs from the preceding epoch',
    () async {
      final r = await _rig();
      var applies = 0;
      r.service.onGroupEntry = (_, body) async {
        applies++;
        return true;
      };
      final wire = (await _frames(chunked: false)).single;
      final first = _receive(r.service, wire);
      await r.link.entered.future;
      final secondWire = WireEnvelope.decode(
        wire,
      ).withFrameId('legacy-next').encode();
      final second = _receive(r.service, secondWire);
      await _until(() => applies == 2);
      expect(applies, 2);
      r.service.onGroupEntry = (_, body) async {
        applies++;
        return true;
      };
      r.link.release.complete();
      await Future.wait([first, second]);
      expect(r.link.acknowledgements, hasLength(1));
      await _receive(r.service, secondWire);
      expect(applies, 3);
      expect(r.link.acknowledgements.last, 'legacy-next');
    },
  );

  test('queued group receipts retain the original physical sender', () async {
    final r = await _rig();
    r.service.onGroupEntry = (_, body) async => true;
    final wire = (await _frames(chunked: false)).single;
    final first = _receive(r.service, wire, device: _id(4));
    await r.link.entered.future;
    final second = _receive(r.service, wire, device: _id(5));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    r.link.release.complete();
    await Future.wait([first, second]);
    expect(r.link.destinations, [_id(4), _id(5)]);
  });

  test(
    'a retry uses the direct route instead of a held group one-time reply',
    () async {
      final r = await _rig();
      r.service.onGroupEntry = (_, body) async => true;
      final wire = (await _frames(chunked: false)).single;
      final first = _receive(r.service, wire, reply: 41);
      await r.link.entered.future;
      final second = _receive(r.service, wire, reply: 42);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      r.link.release.complete();
      await Future.wait([first, second]);
      expect(r.link.replies, [41]);
      expect(r.link.destinations, [_id(2)]);
      expect(r.link.acknowledgements, hasLength(2));
    },
  );

  test(
    'group ACK job cap refuses excess work and a later retry repairs it',
    () async {
      final r = await _rig();
      var applies = 0;
      r.service.onGroupEntry = (_, body) async {
        applies++;
        return true;
      };
      final wire = (await _frames(chunked: false)).single;
      final envelope = WireEnvelope.decode(wire);
      final first = _receive(r.service, wire);
      await r.link.entered.future;
      final rest = [
        for (var i = 0; i < 140; i++)
          _receive(r.service, envelope.withFrameId('legacy-$i').encode()),
      ];
      await _until(() => applies == 141);
      expect(applies, 141);
      expect(r.link.acknowledgements, isEmpty);
      r.link.release.complete();
      await Future.wait([first, ...rest]);
      expect(r.link.acknowledgements, hasLength(128));
      expect(r.link.acknowledgements, isNot(contains('legacy-139')));
      await _receive(r.service, envelope.withFrameId('legacy-139').encode());
      expect(r.link.acknowledgements.last, 'legacy-139');
      expect(applies, 141, reason: 'retry re-ACKs its prior committed effect');
    },
  );

  test(
    'oversized group ACK metadata is refused without blocking later valid work',
    () async {
      final r = await _rig();
      r.link.hold = false;
      var applied = 0;
      r.service.onGroupEntry = (_, body) async {
        applied++;
        return true;
      };
      final wire = (await _frames(chunked: false)).single;
      await _receive(
        r.service,
        WireEnvelope.decode(wire).withFrameId('legacy-${'x' * 24000}').encode(),
      );
      expect(r.link.acknowledgements, isEmpty);
      expect(applied, 0);
      await _receive(r.service, wire);
      expect(r.link.acknowledgements, hasLength(1));
    },
  );

  test(
    'shutdown joins the active group ACK and discards queued transport work',
    () async {
      final r = await _rig();
      var applies = 0;
      r.service.onGroupEntry = (_, body) async {
        applies++;
        return true;
      };
      final wire = (await _frames(chunked: false)).single;
      final first = _receive(r.service, wire);
      await r.link.entered.future;
      final secondWire = WireEnvelope.decode(
        wire,
      ).withFrameId('legacy-next').encode();
      final second = _receive(r.service, secondWire);
      await _until(() => applies == 2);
      expect(applies, 2);
      var closed = false;
      final close = r.service.dispose().then((_) {
        closed = true;
      });
      await second;
      expect(closed, isFalse);
      r.link.release.complete();
      await Future.wait([first, close]);
      expect(r.link.acknowledgements, hasLength(1));
      final reopened = MessagingService(r.link, r.storage);
      addTearDown(reopened.dispose);
      reopened.onGroupEntry = (_, body) async {
        applies++;
        return true;
      };
      await _receive(reopened, secondWire);
      expect(r.link.acknowledgements.last, 'legacy-next');
      expect(applies, 3);
    },
  );
  test(
    'legacy per-slice delivery joins every queued ACK after the complete apply',
    () async {
      final r = await _rig();
      var applied = 0;
      r.service.onGroupEntry = (_, body) async {
        applied++;
        return true;
      };
      final current = await _frames(chunked: true);
      final legacy = [
        for (final wire in current)
          () {
            final env = WireEnvelope.decode(wire);
            final f = parseGroupEntryChunk(env.body);
            return groupEntryChunkEnvelope(
              transferId: f.transferId,
              index: f.index,
              count: f.count,
              data: f.data,
            ).withFrameId(env.frameId!).encode();
          }(),
      ];
      var settled = false;
      final receiving =
          Future.wait([
            for (final wire in legacy) _receive(r.service, wire),
          ]).then((_) {
            settled = true;
          });
      await r.link.entered.future;
      expect(applied, 1);
      expect(settled, isFalse);
      expect(r.link.acknowledgements, isEmpty);
      r.link.release.complete();
      await receiving;
      expect(
        r.link.acknowledgements.toSet(),
        legacy.map((w) => WireEnvelope.decode(w).frameId).toSet(),
      );
    },
  );

  test(
    'pending identical group retries coalesce and a later replay can ACK again',
    () async {
      final r = await _rig();
      var applied = 0;
      r.service.onGroupEntry = (_, body) async {
        applied++;
        return true;
      };
      final wire = (await _frames(chunked: false)).single;
      final first = _receive(r.service, wire);
      await r.link.entered.future;
      final repeats = [for (var i = 0; i < 5; i++) _receive(r.service, wire)];
      await Future<void>.delayed(const Duration(milliseconds: 30));
      r.link.release.complete();
      await Future.wait([first, ...repeats]);
      expect(applied, 1);
      expect(r.link.acknowledgements, hasLength(2));
      await _receive(r.service, wire);
      expect(applied, 1);
      expect(r.link.acknowledgements, hasLength(3));
    },
  );
}

Future<({HiddenVolumeStorage storage, _Link link, MessagingService service})>
_rig() async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'fixture', createIfMissing: true);
  final link = _Link();
  final service = MessagingService(link, storage);
  for (final peer in [_id(2), _id(3)]) {
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
  }
  addTearDown(() async {
    if (!link.release.isCompleted) link.release.complete();
    await service.dispose();
    await storage.close();
    await link.dispose();
  });
  return (storage: storage, link: link, service: service);
}

Future<void> _receive(
  MessagingService service,
  Uint8List wire, {
  NodeId? device,
  int reply = 0,
}) => service.deliverInbound(
  InboundMessage(
    src: _id(2),
    srcDevice: device,
    replyId: reply,
    provenance: SenderProvenance.sessionPeer,
    payload: wire,
  ),
);
