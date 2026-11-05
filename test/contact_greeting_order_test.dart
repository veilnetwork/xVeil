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
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int value) => NodeId(Uint8List(32)..fillRange(0, 32, value));

/// The tests explicitly deliver captured frames, so retries and acceptance
/// happen in a known order without depending on the network or retry timers.
class _Capture extends LoopbackTransport {
  _Capture(NodeId id) : super(localNodeId: id);
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

Future<void> _deliver(MessagingService to, NodeId from, WireEnvelope frame) =>
    to.deliverInbound(
      InboundMessage(
        src: from,
        payload: frame.encode(),
        provenance: SenderProvenance.sessionPeer,
      ),
    );

void main() {
  for (final native in [false, true]) {
    group(
      'greeting position native=$native',
      () {
        final a = _id(1), b = _id(2);
        late HiddenVolumeStorage sA, sB;
        late _Capture tA, tB;
        late MessagingService mA, mB;
        Directory? dir;

        setUp(() async {
          Future<HiddenVolumeStorage> storage(String name) async {
            late HiddenVolumeStorage result;
            if (native) {
              expect(ensureHiddenVolumeLoaded(), isTrue);
              dir ??= await Directory.systemTemp.createTemp('xveil-greeting-');
              final path = '${dir!.path}/$name.hv';
              HvKvLogStore(
                hv.HvSpace.create(
                  path: path,
                  password: Uint8List.fromList(utf8.encode('fixture')),
                  argon: hv.ArgonPreset.min,
                ),
              ).close();
              result = HiddenVolumeStorage.async(workerSpaceOpener(path));
            } else {
              final kv = FakeKvLogStore();
              result = HiddenVolumeStorage(
                ({required password, required bool create}) => kv,
              );
            }
            expect(await result.open(password: 'fixture'), isTrue);
            return result;
          }

          sA = await storage('a');
          sB = await storage('b');
          tA = _Capture(a);
          tB = _Capture(b);
          mA = MessagingService(tA, sA);
          mB = MessagingService(tB, sB);
        });
        tearDown(() async {
          await mA.dispose();
          await mB.dispose();
          await tA.dispose();
          await tB.dispose();
          await sA.close();
          await sB.close();
          await dir?.delete(recursive: true);
          dir = null;
        });

        test(
          'initial request carries the committed greeting position',
          () async {
            await mA.sendRequest(b, 'hello');
            final row = (await sA.loadMessages(b.hex)).single;
            final request = tA.sent.singleWhere(
              (e) => e.kind == WireKind.request,
            );
            expect(request.seq, row.seq);
            expect(request.sentAtMs, row.timestamp.millisecondsSinceEpoch);
            await _deliver(mB, a, request);
            final received = (await sB.loadMessages(a.hex)).single;
            expect(
              (received.orderAuthor, received.orderSeq),
              (row.orderAuthor, row.orderSeq),
            );
          },
        );

        for (final keepDurableRequest in [true, false]) {
          test('manual retry after reopen retains birth metadata '
              'durable=$keepDurableRequest', () async {
            await mA.sendRequest(b, 'hello');
            final row = (await sA.loadMessages(b.hex)).single;
            if (!keepDurableRequest) {
              for (final frame in await sA.pendingOutboxFrames()) {
                await sA.ackOutboxFrame(frame.frameId, fromPeerHex: b.hex);
              }
            }
            await mA.dispose();
            await sA.close();
            expect(await sA.open(password: 'fixture'), isTrue);
            mA = MessagingService(tA, sA);
            tA.sent.clear();
            await mA.resendRequest(b);
            final request = tA.sent.singleWhere(
              (e) => e.kind == WireKind.request,
            );
            expect(request.id, row.id);
            expect(request.seq, row.seq);
            expect(request.sentAtMs, row.timestamp.millisecondsSinceEpoch);
            final persisted = (await sA.pendingOutboxFrames()).single;
            expect(WireEnvelope.decode(persisted.wire).seq, row.seq);
            expect(
              WireEnvelope.decode(persisted.wire).sentAtMs,
              row.timestamp.millisecondsSinceEpoch,
            );
          });
        }

        test(
          'legacy durable request is upgraded from its committed row',
          () async {
            await mA.sendRequest(b, 'hello');
            final row = (await sA.loadMessages(b.hex)).single;
            final request = (await sA.pendingOutboxFrames()).single;
            await sA.enqueueOutboxFrame(
              request.frameId,
              b.hex,
              WireEnvelope.request(
                'hello',
                id: row.id,
                sentAtMs: row.timestamp.millisecondsSinceEpoch,
              ).withFrameId(request.frameId).encode(),
            );
            tA.sent.clear();
            await mA.resendRequest(b);
            final retry = tA.sent.singleWhere(
              (e) => e.kind == WireKind.request,
            );
            expect(retry.id, row.id);
            expect(retry.seq, row.seq);
            expect(retry.sentAtMs, row.timestamp.millisecondsSinceEpoch);
          },
        );

        test('an empty request creates no phantom message position', () async {
          await mA.sendRequest(b, '');
          final request = tA.sent.singleWhere(
            (e) => e.kind == WireKind.request,
          );
          expect(request.seq, isNull);
          expect(await sA.loadMessages(b.hex), isEmpty);
          await _deliver(mB, a, request);
          expect(await sB.loadMessages(a.hex), isEmpty);
          expect(
            (await sB.getContact(a))!.status,
            ContactStatus.pendingIncoming,
          );
          await mA.resendRequest(b);
          expect(
            tA.sent.lastWhere((e) => e.kind == WireKind.request).seq,
            isNull,
          );
        });

        test(
          'repeated undecided request preserves convergent display order',
          () async {
            await mA.sendRequest(b, 'hello');
            final request = tA.sent.singleWhere(
              (e) => e.kind == WireKind.request,
            );
            // This same retry pattern assigned the greeting seq=4 at the receiver,
            // while the sender still had seq=1. No artificial ordering rows.
            for (var i = 0; i < 4; i++) {
              await _deliver(mB, a, request);
            }
            await mB.acceptContact(a);
            await _deliver(
              mA,
              b,
              tB.sent.lastWhere((e) => e.kind == WireKind.accept),
            );
            await mA.sendText(b, 'later');
            final text = tA.sent.lastWhere((e) => e.kind == WireKind.message);
            await _deliver(mB, a, text);
            final sent = await sA.loadMessages(b.hex);
            final received = await sB.loadMessages(a.hex);
            expect(sent.map((m) => m.body), ['hello', 'later']);
            expect(received.map((m) => m.id), sent.map((m) => m.id));
            expect(
              received.map((m) => (m.orderAuthor, m.orderSeq)),
              sent.map((m) => (m.orderAuthor, m.orderSeq)),
            );
            expect(received.map((m) => m.id).toSet(), hasLength(2));
            // Reopen proves this is the durable fold, not a warm projection fix.
            await sB.close();
            expect(await sB.open(password: 'fixture'), isTrue);
            expect(
              (await sB.loadMessages(a.hex)).map((m) => m.id),
              sent.map((m) => m.id),
            );
          },
        );

        test(
          'legacy same-id intro update keeps its first local position',
          () async {
            final request = const WireEnvelope.request('hello', id: 'legacy');
            await _deliver(mB, a, request);
            final first = (await sB.loadMessages(a.hex)).single;
            await _deliver(
              mB,
              a,
              const WireEnvelope.request('updated intro', id: 'legacy'),
            );
            final updated = (await sB.loadMessages(a.hex)).single;
            expect(updated.body, 'updated intro');
            expect(updated.seq, first.seq);
            expect(updated.timestamp, first.timestamp);
          },
        );
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
  }
}
