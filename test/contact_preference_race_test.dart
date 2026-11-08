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
import 'package:xveil/domain/clear_policy.dart';
import 'package:xveil/domain/disappearing_messages.dart';
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/state/messaging.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Held extends HiddenVolumeStorage {
  _Held(super.open) : super.async();
  bool armed = false, holdRead = false, failAfterTransform = false;
  final entered = Completer<void>(), release = Completer<void>();
  Future<void> hold() async {
    if (armed) {
      armed = false;
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<Contact?> getContact(NodeId peer) async {
    final current = await super.getContact(peer);
    if (holdRead) {
      holdRead = false;
      entered.complete();
      await release.future;
    }
    return current;
  }

  @override
  Future<Contact?> updateContactPrefs(
    NodeId peer,
    Contact? Function(Contact) update, {
    bool queueForSync = false,
    String? onlyIfLocalPrefsToken,
  }) async {
    await hold();
    return super.updateContactPrefs(
      peer,
      (current) {
        final next = update(current);
        if (failAfterTransform) {
          failAfterTransform = false;
          throw StateError('injected refusal after transform');
        }
        return next;
      },
      queueForSync: queueForSync,
      onlyIfLocalPrefsToken: onlyIfLocalPrefsToken,
    );
  }

  @override
  Future<void> upsertContact(Contact contact) async {
    await hold();
    await super.upsertContact(contact);
  }
}

class _Wire extends LoopbackTransport {
  _Wire({NodeId? local}) : super(localNodeId: local ?? id(1));
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

Future<bool> _mirror(MessagingService s, {DisappearingSetting? policy}) =>
    s.applyMirroredContact(
      peer: id(2),
      name: 'mirror',
      pinned: false,
      archived: false,
      allowPeerDelete: true,
      clearPolicy: kDefaultClearRequestPolicy,
      disappearing: policy,
    );

class _Fixture {
  _Fixture(this.storage, this.wire, this.service, this.dir);
  final _Held storage;
  final _Wire wire;
  final MessagingService service;
  final Directory? dir;
  Future<void> close() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await service.dispose();
    await wire.dispose();
    await storage.close();
    await dir?.delete(recursive: true);
  }
}

Future<_Fixture> _fixture(bool native, {DateTime? now, NodeId? self}) async {
  Directory? dir;
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), true);
    dir = await Directory.systemTemp.createTemp('xveil-pref-control-');
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
    final kv = FakeKvLogStore();
    open = ({required password, required bool create}) async =>
        SyncWrappedAsyncKvLogStore(kv);
  }
  final storage = _Held(open), wire = _Wire(local: self);
  final f = _Fixture(
    storage,
    wire,
    MessagingService(wire, storage, now: now == null ? null : () => now),
    dir,
  );
  addTearDown(f.close);
  expect(await storage.open(password: 'fixture', createIfMissing: true), true);
  await storage.upsertContact(Contact(nodeId: id(2), name: 'original'));
  return f;
}

void main() {
  for (final native in [false, true]) {
    test(
      'durable publication echo checks floor inside write turn native=$native',
      () async {
        final f = await _fixture(native), s = f.storage, svc = f.service;
        await svc.setContactName(id(2), 'old');
        final old = (await s.pendingContactPreferences()).single;
        s.armed = true;
        final echo = svc.applyMirroredContact(
          peer: id(2),
          name: 'old',
          pinned: false,
          archived: false,
          allowPeerDelete: true,
          clearPolicy: kDefaultClearRequestPolicy,
          onlyIfLocalPrefsToken: old.token,
        );
        await s.entered.future;
        await svc.setContactPinned(id(2), true);
        s.release.complete();
        expect(await echo, false);
        expect((await s.getContact(id(2)))!.pinned, true);
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null
          ? 'set XVEIL_HV_DYLIB to a qualified native library'
          : false,
    );
    test(
      'same-clock policy delivery keeps both recipients native=$native',
      () async {
        final fixed = DateTime.now().toUtc();
        final f = await _fixture(native, now: fixed);
        final s = f.storage, svc = f.service;
        for (final p in [id(2), id(3)]) {
          await s.upsertContact(
            Contact(nodeId: p, status: ContactStatus.accepted),
          );
        }
        await svc.setContactDisappearing(id(2), 60);
        await svc.setContactDisappearing(id(3), 120);
        final frames = (await s.pendingOutboxFrames())
            .where((f) => f.frameId.startsWith('disap:'))
            .toList();
        expect(
          frames.map((f) => f.peerHex).toSet(),
          {id(2).hex, id(3).hex},
          reason: 'both offline destinations must retain their own obligation',
        );
        expect(frames.map((f) => f.frameId).toSet(), hasLength(2));
        final byPeer = {for (final frame in frames) frame.peerHex: frame};
        for (final peer in [id(2), id(3)]) {
          final row = byPeer[peer.hex]!;
          final env = WireEnvelope.decode(row.wire);
          expect(env.kind, WireKind.disappearingSet);
          expect(
            (jsonDecode(env.body) as Map)['ttl'],
            peer == id(2) ? 60 : 120,
          );
          // Repeating the SAME recipient/revision must still deduplicate.
          await svc.sendDurable(peer, row.frameId, env);
        }
        expect(await s.pendingOutboxFrames(), hasLength(2));
        await svc.dispose();
        await s.close();
        expect(await s.open(password: 'fixture'), true);
        var sender = MessagingService(f.wire, s, now: () => fixed);
        addTearDown(() => sender.dispose());
        expect((await s.pendingOutboxFrames()).map((f) => f.peerHex).toSet(), {
          id(2).hex,
          id(3).hex,
        });
        Future<void> receive(
          MessagingService receiver,
          NodeId source,
          Uint8List wire,
        ) => receiver.deliverInbound(
          InboundMessage(
            src: source,
            payload: wire,
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        final receivers = <int, _Fixture>{};
        for (final n in [2, 3]) {
          final receiver = await _fixture(native, self: id(n));
          receivers[n] = receiver;
          await receiver.storage.upsertContact(
            Contact(nodeId: id(1), status: ContactStatus.accepted),
          );
          final row = byPeer[id(n).hex]!;
          await receive(receiver.service, id(1), row.wire);
          await receive(receiver.service, id(1), row.wire);
          final policy = (await receiver.storage.getContact(id(1)))!;
          expect(policy.disappearingTtlSeconds, n == 2 ? 60 : 120);
          expect(policy.disappearingSetAtMs, fixed.millisecondsSinceEpoch);
          expect(policy.disappearingSetBy, id(1).hex);
          expect(
            (await receiver.storage.loadMessages(
              id(1).hex,
            )).where((m) => m.id.startsWith('sys:disap:')),
            hasLength(1),
          );
        }
        Uint8List ack(int n) => receivers[n]!.wire.sent.firstWhere(
          (wire) => WireEnvelope.decode(wire).kind == WireKind.ack,
        );
        // A valid contact cannot acknowledge another recipient's obligation.
        await receive(sender, id(3), ack(2));
        expect(await s.pendingOutboxFrames(), hasLength(2));
        await receive(sender, id(2), ack(2));
        expect((await s.pendingOutboxFrames()).single.peerHex, id(3).hex);
        await sender.dispose();
        await s.close();
        expect(await s.open(password: 'fixture'), true);
        sender = MessagingService(f.wire, s, now: () => fixed);
        expect((await s.pendingOutboxFrames()).single.peerHex, id(3).hex);
        await receive(sender, id(3), ack(3));
        expect(await s.pendingOutboxFrames(), isEmpty);
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null
          ? 'set XVEIL_HV_DYLIB to a qualified native library'
          : false,
    );
    for (final mode in ['latest', 'other-peer', 'failed', 'closed']) {
      test(
        'own preference witness native=$native mode=$mode',
        () async {
          final f = await _fixture(native);
          final s = f.storage, svc = f.service, p = id(2);
          final snapshots = <Contact>[];
          svc.onContactPrefsChanged = snapshots.add;
          await svc.setContactPinned(p, true);
          final latest = snapshots.single;
          if (mode == 'closed') {
            await svc.dispose();
            expect(svc.isCurrentContactPrefsSnapshot(latest), false);
            return;
          }
          if (mode == 'failed') {
            s.failAfterTransform = true;
            await expectLater(svc.setContactPinned(p, false), throwsStateError);
          }
          if (mode == 'other-peer') {
            await s.upsertContact(Contact(nodeId: id(3)));
            await svc.setContactName(id(3), 'independent');
          }
          expect(svc.isCurrentContactPrefsSnapshot(latest), true);
          // An ordinary sibling apply remains admissible, and must not discard
          // the witness needed by the newer own-event echo already in flight.
          await _mirror(svc);
          expect((await s.getContact(p))!.pinned, false);
          expect(
            await svc.applyMirroredContact(
              peer: p,
              name: latest.name,
              pinned: latest.pinned,
              archived: latest.archived,
              allowPeerDelete: latest.allowPeerDelete,
              clearPolicy: latest.clearPolicy,
              shouldApply: () => svc.isCurrentContactPrefsSnapshot(latest),
            ),
            true,
          );
          expect((await s.getContact(p))!.pinned, true);
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null
            ? 'set XVEIL_HV_DYLIB to a qualified native library'
            : false,
      );
    }
    for (final delayed in [false, true]) {
      test(
        'local preference echo native=$native delayed=$delayed',
        () async {
          final f = await _fixture(native);
          final s = f.storage, svc = f.service, p = id(2);
          final snapshots = <Contact>[];
          svc.onContactPrefsChanged = snapshots.add;
          await svc.setContactName(p, 'first snapshot');
          final old = snapshots.single;
          Future<bool> echo() => svc.applyMirroredContact(
            peer: p,
            name: old.name,
            pinned: old.pinned,
            archived: old.archived,
            allowPeerDelete: old.allowPeerDelete,
            clearPolicy: old.clearPolicy,
            shouldApply: () => svc.isCurrentContactPrefsSnapshot(old),
          );
          Future<bool>? pending;
          if (delayed) {
            s.armed = true;
            pending = echo();
            await s.entered.future;
          }
          await svc.setContactPinned(p, true);
          if (pending == null) {
            pending = echo();
          } else {
            s.release.complete();
          }
          await pending;
          expect(
            (await s.getContact(p))!.pinned,
            true,
            reason: 'a local echo must not undo a later committed action',
          );
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null
            ? 'set XVEIL_HV_DYLIB to a qualified native library'
            : false,
      );
    }
    for (final mode in ['contract', 'clock', 'halves', 'close', 'adopt']) {
      test(
        'atomic preference control native=$native mode=$mode',
        () async {
          final fixed = DateTime.utc(2024, 1, 1);
          final f = await _fixture(native, now: fixed);
          final s = f.storage, p = id(2), svc = f.service;
          if (mode == 'contract') {
            var invoked = false;
            expect(
              await s.updateContactPrefs(id(9), (c) {
                invoked = true;
                return c;
              }),
              isNull,
            );
            expect(invoked, false);
            await expectLater(
              s.updateContactPrefs(
                p,
                (c) => c.copyWith(status: ContactStatus.blocked),
              ),
              throwsArgumentError,
            );
            await expectLater(
              s.updateContactPrefs(
                p,
                (c) => Contact(nodeId: id(3), status: c.status),
              ),
              throwsArgumentError,
            );
            await expectLater(
              s.updateContactPrefs(
                p,
                (_) => throw StateError('refused transform'),
              ),
              throwsStateError,
            );
            await svc.blockContact(p);
            final decision = (await s.pendingContactDecisions()).single;
            await svc.setContactName(p, 'kept decision');
            expect((await s.contactDecisionFloor(p))?.atMs, decision.atMs);
            expect(
              (await s.pendingContactDecisions()).single.token,
              decision.token,
            );
            expect((await s.getContact(p))?.status, ContactStatus.blocked);
          } else if (mode == 'clock') {
            await svc.setContactDisappearing(p, 60);
            await svc.setContactHideAfterRead(p, 10);
            await svc.setContactDisappearing(p, null);
            final frames = (await s.pendingOutboxFrames())
                .where((r) => r.frameId.startsWith('disap:'))
                .toList();
            expect(
              frames,
              hasLength(3),
              reason: 'same-tick actions must not overwrite one durable frame',
            );
            final settings = [
              for (final r in frames)
                DisappearingSetting.fromWireJson(
                  Map<String, Object?>.from(
                    jsonDecode(WireEnvelope.decode(r.wire).body) as Map,
                  ),
                  id(1),
                  now: fixed,
                )!,
            ];
            settings.sort((a, b) => a.setAtMs.compareTo(b.setAtMs));
            expect(settings.map((r) => r.setAtMs).toSet(), hasLength(3));
            var remote = DisappearingSetting.off;
            for (final next in settings) {
              remote = DisappearingSetting.winner(remote, next);
            }
            expect(remote.ttlSeconds, isNull);
            expect(remote.hideAfterReadSeconds, 10);
            final c = (await s.getContact(p))!;
            expect(c.disappearingSetAtMs, remote.setAtMs);
          } else if (mode == 'halves') {
            s.armed = true;
            final first = svc.setContactDisappearing(p, 60);
            await s.entered.future;
            await svc.setContactHideAfterRead(p, 10);
            s.release.complete();
            await first;
            final c = (await s.getContact(p))!;
            expect(c.disappearingTtlSeconds, 60);
            expect(c.hideAfterReadSeconds, 10);
          } else if (mode == 'close') {
            final emitted = <Contact>[];
            svc.onContactPrefsChanged = emitted.add;
            s.holdRead = true;
            final update = svc.setContactName(p, 'committed before close');
            await s.entered.future;
            await svc.dispose();
            var closed = false;
            final closing = s.close().then((_) => closed = true);
            await pumpEventQueue();
            expect(
              closed,
              false,
              reason: 'closing must join the pinned storage turn',
            );
            s.release.complete();
            await update;
            await closing;
            expect(emitted, isEmpty);
            expect(await s.open(password: 'fixture'), true);
            expect((await s.getContact(p))?.name, 'committed before close');
            await expectLater(
              svc.setContactName(p, 'stale owner'),
              throwsStateError,
            );
            expect((await s.getContact(p))?.name, 'committed before close');
          } else {
            s.armed = true;
            final incoming = svc.deliverInbound(
              InboundMessage(
                src: p,
                provenance: SenderProvenance.sessionPeer,
                payload: WireEnvelope(
                  WireKind.disappearingSet,
                  jsonEncode({
                    'v': 1,
                    'ttl': 10,
                    'ts': fixed.millisecondsSinceEpoch - 1000,
                  }),
                ).encode(),
              ),
            );
            expect(
              await Future.any([
                s.entered.future.then((_) => true),
                incoming.then((_) => false),
              ]),
              true,
              reason: 'the policy must reach its storage admission gate',
            );
            await svc.setContactDisappearing(p, 45);
            s.release.complete();
            await incoming;
            expect((await s.getContact(p))?.disappearingTtlSeconds, 45);
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
    for (final mode in [
      'rename-accept',
      'rename-block',
      'mirror-block',
      'p2p-block',
      'ttl-block',
      'retention-block',
      'mirror-p2p',
      'rename-ttl',
      'mirror-ttl',
      'rename-archive',
      'rename-remove',
      'other-peer',
    ]) {
      test(
        'preferences preserve concurrent contact state native=$native mode=$mode',
        () async {
          Directory? dir;
          late AsyncSpaceOpener open;
          if (native) {
            expect(ensureHiddenVolumeLoaded(), true);
            dir = await Directory.systemTemp.createTemp('xveil-pref-race-');
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
            final kv = FakeKvLogStore();
            open = ({required password, required bool create}) async =>
                SyncWrappedAsyncKvLogStore(kv);
          }
          final storage = _Held(open), wire = _Wire();
          final service = MessagingService(wire, storage);
          Future<dynamic>? first;
          final emitted = <Contact>[];
          service.onContactPrefsChanged = emitted.add;
          try {
            expect(
              await storage.open(password: 'fixture', createIfMissing: true),
              true,
            );
            await storage.upsertContact(
              Contact(
                nodeId: id(2),
                name: 'original',
                status: mode == 'rename-accept'
                    ? ContactStatus.pendingIncoming
                    : ContactStatus.accepted,
                p2pOverride: ContactP2POverride.allow,
              ),
            );
            storage.armed = true;
            first = switch (mode) {
              'mirror-block' || 'mirror-p2p' => _mirror(service),
              'mirror-ttl' => _mirror(
                service,
                policy: DisappearingSetting(
                  ttlSeconds: 10,
                  setAtMs: 2000,
                  setBy: id(3).hex,
                ),
              ),
              'p2p-block' => service.setContactP2POverride(
                id(2),
                ContactP2POverride.deny,
              ),
              'ttl-block' => service.setContactDisappearing(id(2), 60),
              'retention-block' => service.setContactRetention(id(2), 7),
              _ => service.setContactName(id(2), 'renamed'),
            };
            await storage.entered.future;
            if (mode == 'rename-accept') {
              await service.acceptContact(id(2));
            } else if (mode == 'mirror-p2p') {
              await service.setContactP2POverride(
                id(2),
                ContactP2POverride.deny,
              );
            } else if (mode == 'rename-ttl' || mode == 'mirror-ttl') {
              await service.setContactDisappearing(id(2), 45);
            } else if (mode == 'rename-archive') {
              await service.setContactArchived(id(2), true);
            } else if (mode == 'rename-remove') {
              await storage.removeConversation(id(2));
            } else {
              await service.blockContact(mode == 'other-peer' ? id(3) : id(2));
            }
            storage.release.complete();
            await first;
            final c = await storage.getContact(id(2));
            if (mode == 'rename-remove') {
              expect(c, isNull);
              expect(emitted, isEmpty);
            } else {
              expect(
                c?.status,
                mode.endsWith('block')
                    ? ContactStatus.blocked
                    : ContactStatus.accepted,
              );
              if (mode == 'mirror-p2p') {
                expect(c?.p2pOverride, ContactP2POverride.deny);
              }
              if (mode == 'rename-ttl' || mode == 'mirror-ttl') {
                expect(c?.disappearingTtlSeconds, 45);
              }
              if (mode == 'rename-archive') expect(c?.archived, true);
              if (mode.startsWith('rename') || mode == 'other-peer') {
                expect(c?.name, 'renamed');
              }
            }
            await service.dispose();
            await storage.close();
            expect(await storage.open(password: 'fixture'), true);
            final cold = await storage.getContact(id(2));
            expect(cold?.status, c?.status);
            expect(cold?.name, c?.name);
            expect(cold?.p2pOverride, c?.p2pOverride);
            expect(cold?.disappearingTtlSeconds, c?.disappearingTtlSeconds);
            expect(cold?.archived, c?.archived);
          } finally {
            if (!storage.release.isCompleted) storage.release.complete();
            await first;
            await service.dispose();
            await wire.dispose();
            await storage.close();
            await dir?.delete(recursive: true);
          }
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
  }
}
