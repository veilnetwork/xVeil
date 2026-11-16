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

class _DecisionGateStorage extends HiddenVolumeStorage {
  _DecisionGateStorage(super.opener);
  _DecisionGateStorage.async(super.opener) : super.async();
  bool holdDecision = false;
  final decisionEntered = Completer<void>();
  final decisionRelease = Completer<void>();

  @override
  Future<Contact?> getContact(NodeId peer) async {
    final contact = await super.getContact(peer);
    if (holdDecision) {
      holdDecision = false;
      decisionEntered.complete();
      await decisionRelease.future;
    }
    return contact;
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
              result = _DecisionGateStorage.async(workerSpaceOpener(path));
            } else {
              final kv = FakeKvLogStore();
              result = _DecisionGateStorage(
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
          'a stale request action cannot demote an accepted conversation',
          () async {
            await mA.sendRequest(b, 'hello');
            await _deliver(
              mB,
              a,
              tA.sent.singleWhere((e) => e.kind == WireKind.request),
            );
            await mB.acceptContact(a);
            await _deliver(
              mA,
              b,
              tB.sent.singleWhere((e) => e.kind == WireKind.accept),
            );
            expect((await sA.getContact(b))?.status, ContactStatus.accepted);
            expect((await sB.getContact(a))?.status, ContactStatus.accepted);
            tA.sent.clear();
            tB.sent.clear();

            // A mounted composer may still carry the pre-accept contact value.
            // Do not deliver any repair accept before checking reverse delivery.
            await mA.sendRequest(b, 'sent after acceptance');
            expect((await sA.getContact(b))?.status, ContactStatus.accepted);
            final post = tA.sent.singleWhere((e) => e.kind == WireKind.message);
            await _deliver(mB, a, post);
            await mB.sendText(a, 'reply after acceptance');
            await _deliver(
              mA,
              b,
              tB.sent.lastWhere((e) => e.kind == WireKind.message),
            );
            expect(
              (await sA.loadMessages(
                b.hex,
              )).where((m) => m.body == 'reply after acceptance'),
              hasLength(1),
            );
            expect(
              (await sB.loadMessages(
                a.hex,
              )).where((m) => m.body == 'sent after acceptance'),
              hasLength(1),
            );
          },
        );

        for (final decision in [
          ContactStatus.accepted,
          ContactStatus.blocked,
        ]) {
          test(
            'request queued behind $decision preserves the committed decision',
            () async {
              await sA.upsertContact(
                Contact(nodeId: b, status: ContactStatus.pendingIncoming),
              );
              final gated = sA as _DecisionGateStorage;
              gated.holdDecision = true;
              addTearDown(() {
                if (!gated.decisionRelease.isCompleted) {
                  gated.decisionRelease.complete();
                }
              });
              final statuses = <ContactStatus>[];
              mA.onContactStatusChanged = (_, status) => statuses.add(status);
              final deciding = decision == ContactStatus.accepted
                  ? mA.acceptContact(b)
                  : mA.blockContact(b);
              await gated.decisionEntered.future;
              final sending = mA.sendRequest(
                b,
                'typed before decision completed',
              );
              gated.decisionRelease.complete();
              await deciding;
              final submitted = await sending;
              expect((await sA.getContact(b))?.status, decision);
              expect(statuses, isNot(contains(ContactStatus.pendingOutgoing)));
              expect(tA.sent.where((e) => e.kind == WireKind.request), isEmpty);
              expect(submitted, decision == ContactStatus.accepted);
              expect(
                tA.sent.where((e) => e.kind == WireKind.message),
                hasLength(decision == ContactStatus.accepted ? 1 : 0),
              );
              await sA.close();
              expect(await sA.open(password: 'fixture'), isTrue);
              expect((await sA.getContact(b))?.status, decision);
            },
          );
        }

        test(
          'empty stale request leaves an accepted contact and history intact',
          () async {
            await sA.upsertContact(
              Contact(nodeId: b, status: ContactStatus.accepted),
            );
            expect(await mA.sendRequest(b, ''), isTrue);
            expect((await sA.getContact(b))?.status, ContactStatus.accepted);
            expect(tA.sent, isEmpty);
            expect(await sA.loadMessages(b.hex), isEmpty);
            expect(await sA.pendingOutboxFrames(), isEmpty);
          },
        );

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

        for (final reopen in [false, true]) {
          test(
            'crossed requests need only one explicit acceptance reopen=$reopen',
            () async {
              await Future.wait([
                mA.sendRequest(b, 'hello from a'),
                mB.sendRequest(a, 'hello from b'),
              ]);
              final requestA = tA.sent.singleWhere(
                (e) => e.kind == WireKind.request,
              );
              final requestB = tB.sent.singleWhere(
                (e) => e.kind == WireKind.request,
              );
              await Future.wait([
                _deliver(mA, b, requestB),
                _deliver(mB, a, requestA),
              ]);
              expect(
                (await sA.getContact(b))?.status,
                ContactStatus.pendingIncoming,
              );
              expect(
                (await sB.getContact(a))?.status,
                ContactStatus.pendingIncoming,
              );
              if (reopen) {
                await mA.dispose();
                await sA.close();
                expect(await sA.open(password: 'fixture'), isTrue);
                mA = MessagingService(tA, sA);
              }
              await mB.acceptContact(a);
              await _deliver(
                mA,
                b,
                tB.sent.lastWhere((e) => e.kind == WireKind.accept),
              );
              expect(
                (await sA.getContact(b))?.status,
                ContactStatus.accepted,
                reason:
                    'receiving a request must not erase our own prior request consent',
              );
              await mA.sendText(b, 'after crossed requests');
              await _deliver(
                mB,
                a,
                tA.sent.lastWhere((e) => e.kind == WireKind.message),
              );
              await mB.sendText(a, 'reverse after crossed requests');
              await _deliver(
                mA,
                b,
                tB.sent.lastWhere((e) => e.kind == WireKind.message),
              );
              expect(
                (await sB.loadMessages(
                  a.hex,
                )).where((m) => m.body == 'after crossed requests'),
                hasLength(1),
              );
              expect(
                (await sA.loadMessages(
                  b.hex,
                )).where((m) => m.body == 'reverse after crossed requests'),
                hasLength(1),
              );
            },
          );
        }

        for (final reopen in [false, true]) {
          test(
            'incoming-only request never authorizes an accept reopen=$reopen',
            () async {
              await mB.sendRequest(a, 'only incoming');
              await _deliver(
                mA,
                b,
                tB.sent.singleWhere((e) => e.kind == WireKind.request),
              );
              if (reopen) {
                await mA.dispose();
                await sA.close();
                expect(await sA.open(password: 'fixture'), isTrue);
                mA = MessagingService(tA, sA);
              }
              await _deliver(
                mA,
                b,
                const WireEnvelope.accept().withFrameId('unsolicited-accept'),
              );
              final contact = await sA.getContact(b);
              expect(contact?.status, ContactStatus.pendingIncoming);
              expect(contact?.hasOutgoingRequest, isFalse);
              expect(contact?.canMessage, isFalse);
            },
          );
        }

        test(
          'a presentation upsert preserves crossed outgoing consent',
          () async {
            await Future.wait([
              mA.sendRequest(b, 'from a'),
              mB.sendRequest(a, 'from b'),
            ]);
            await _deliver(
              mA,
              b,
              tB.sent.singleWhere((e) => e.kind == WireKind.request),
            );
            await _deliver(
              mB,
              a,
              tA.sent.singleWhere((e) => e.kind == WireKind.request),
            );
            await sA.upsertContact(
              Contact(
                nodeId: b,
                name: 'Local label',
                status: ContactStatus.pendingIncoming,
              ),
            );
            await mB.acceptContact(a);
            await _deliver(
              mA,
              b,
              tB.sent.lastWhere((e) => e.kind == WireKind.accept),
            );
            expect((await sA.getContact(b))?.status, ContactStatus.accepted);
            expect((await sA.getContact(b))?.name, 'Local label');
            expect((await sA.getContact(b))?.hasOutgoingRequest, isFalse);
          },
        );

        test('forgetting crossed requests clears outgoing consent', () async {
          await Future.wait([
            mA.sendRequest(b, 'from a'),
            mB.sendRequest(a, 'from b'),
          ]);
          await _deliver(
            mA,
            b,
            tB.sent.singleWhere((e) => e.kind == WireKind.request),
          );
          await _deliver(
            mB,
            a,
            tA.sent.singleWhere((e) => e.kind == WireKind.request),
          );
          await mB.acceptContact(a);
          final oldAccept = tB.sent.lastWhere((e) => e.kind == WireKind.accept);
          await mA.cancelRequest(b);
          expect(await sA.getContact(b), isNull);
          await _deliver(
            mA,
            b,
            const WireEnvelope.request('new incoming', id: 'fresh-intro'),
          );
          await _deliver(mA, b, oldAccept);
          final contact = await sA.getContact(b);
          expect(contact?.status, ContactStatus.pendingIncoming);
          expect(contact?.hasOutgoingRequest, isFalse);
          await mB.sendText(a, 'still needs consent');
          await _deliver(
            mA,
            b,
            tB.sent.lastWhere((e) => e.kind == WireKind.message),
          );
          expect(
            (await sA.loadMessages(
              b.hex,
            )).where((m) => m.body == 'still needs consent'),
            isEmpty,
          );
        });

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
