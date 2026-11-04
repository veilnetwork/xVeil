import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilClient, VeilEvent;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/state/mailbox_orchestrator.dart';
import 'package:xveil/state/mailbox_service.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/core/error_journal.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Client implements VeilClient {
  final events_ = StreamController<VeilEvent>.broadcast();
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #events) return events_.stream;
    if (i.memberName == #lookupRelayX25519) {
      return Future<({Uint8List key, int validUntilUnix})?>.value((
        key: Uint8List(32),
        validUntilUnix: 0,
      ));
    }
    if (i.memberName == #registerRendezvousPublisher) {
      return Future<void>.value();
    }
    return super.noSuchMethod(i);
  }
}

class _ObservedDrain extends MailboxOrchestrator {
  _ObservedDrain(super.crypto, super.relay);
  final finished = Completer<void>();
  @override
  Future<List<DrainedMessage>> drain({
    required NodeId me,
    required Uint8List authCookie,
    required int ourCertVersion,
    required Future<bool> Function(Uint8List) alreadyHave,
    List<NodeId> knownRelays = const [],
    bool Function()? shouldContinue,
    Future<bool> Function(DrainedMessage)? onMessage,
  }) async {
    try {
      return await super.drain(
        me: me,
        authCookie: authCookie,
        ourCertVersion: ourCertVersion,
        alreadyHave: alreadyHave,
        knownRelays: knownRelays,
        shouldContinue: shouldContinue,
        onMessage: onMessage,
      );
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }
}

class _PendingStore extends HiddenVolumeStorage {
  _PendingStore(FakeKvLogStore kv)
    : super(({required password, required bool create}) => kv);
  bool hold = false;
  bool failContactRead = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Contact?> getContact(NodeId peer) {
    if (failContactRead) throw StateError('PRIVATE_CONTACT_LOOKUP');
    return super.getContact(peer);
  }

  @override
  Future<void> enqueueOutboxFrame(
    String id,
    String peer,
    Uint8List bytes,
  ) async {
    if (hold && id == 'accept:$peer') {
      hold = false;
      entered.complete();
      await release.future;
    }
    await super.enqueueOutboxFrame(id, peer, bytes);
  }
}

class _ReceiptWire extends LoopbackTransport {
  _ReceiptWire(this.hold) : super(localNodeId: _id(1));
  final bool hold;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> send(
    NodeId dst,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    if (WireEnvelope.decode(bytes).kind == WireKind.ack) {
      if (!entered.isCompleted) entered.complete();
      if (hold) await release.future;
    }
  }
}

void main() {
  for (final mode in ['storage', 'receipt', 'closed', 'lookup-failure']) {
    test(
      'mailbox responsibility follows durable processing mode=$mode',
      () async {
        final me = _id(1), peer = _id(2), client = _Client();
        final relay = InMemoryMailboxRelay();
        final orch = _ObservedDrain(
          LoopbackMailboxCrypto(senderForOpen: peer),
          relay,
        );
        final storage = _PendingStore(FakeKvLogStore())
          ..hold = mode == 'storage';
        final wire = _ReceiptWire(mode == 'receipt');
        final messaging = MessagingService(wire, storage);
        Future<void>? handled;
        final service = MailboxService(
          client: client,
          me: me,
          orchestrator: orch,
          deliver: (m) =>
              handled = messaging.deliverInbound(m, waitForReceipts: false),
          drainInterval: const Duration(days: 1),
        );
        try {
          errorJournal.clear();
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            true,
          );
          await storage.upsertContact(
            Contact(nodeId: peer, status: ContactStatus.accepted),
          );
          storage.failContactRead = mode == 'lookup-failure';
          if (mode == 'closed') await messaging.dispose();
          final payload = const WireEnvelope.request(
            '',
            id: 'intro',
          ).withFrameId('intro-frame').encode();
          await orch.stash(
            me: peer,
            recipient: me,
            appId: Uint8List(32),
            endpointId: 1,
            data: payload,
            contentId: Uint8List(32),
          );
          await service.start(relays: [_id(7)]);
          await orch.finished.future;
          final remaining = await relay.fetch(me: me, authCookie: Uint8List(0));
          expect(remaining, mode == 'receipt' ? isEmpty : hasLength(1));
          final rows = await storage.pendingOutboxFrames();
          expect(
            rows.any((f) => f.frameId == 'accept:${peer.hex}'),
            mode == 'receipt',
          );
          if (mode == 'storage') {
            expect(storage.entered.isCompleted, true);
            expect(storage.release.isCompleted, false);
            storage.release.complete();
            await handled;
            expect(
              (await storage.pendingOutboxFrames()).any(
                (f) => f.frameId == 'accept:${peer.hex}',
              ),
              true,
            );
            expect(
              await relay.fetch(me: me, authCookie: Uint8List(0)),
              hasLength(1),
            );
          }
          if (mode == 'receipt') {
            await wire.entered.future;
            expect(wire.release.isCompleted, false);
          }
        } finally {
          if (!storage.release.isCompleted) storage.release.complete();
          if (!wire.release.isCompleted) wire.release.complete();
          await handled;
          await service.dispose();
          await messaging.dispose();
          await wire.dispose();
          await storage.close();
          await client.events_.close();
          errorJournal.clear();
        }
      },
    );
  }
  for (final mode in [
    'pending-success',
    'pending-refusal',
    'async-error',
    'sync-error',
    'success',
    'refusal',
    'failure-then-success',
  ]) {
    test('mailbox deletes only accepted delivery mode=$mode', () async {
      final me = _id(1), peer = _id(2);
      final relay = InMemoryMailboxRelay();
      _ObservedDrain orchestrator() =>
          _ObservedDrain(LoopbackMailboxCrypto(senderForOpen: peer), relay);
      final orch = orchestrator(), client = _Client();
      final gate = Completer<void>(), entered = Completer<void>();
      var committed = 0;
      var calls = 0;
      Future<void> deliver(InboundMessage m) {
        calls++;
        if (!entered.isCompleted) entered.complete();
        if (mode == 'sync-error') throw StateError('PRIVATE_LOCAL_STORAGE');
        return () async {
          if (mode.startsWith('pending-')) await gate.future;
          if (mode == 'async-error' ||
              mode == 'failure-then-success' && m.payload.first == 1) {
            throw StateError('PRIVATE_LOCAL_STORAGE');
          }
          if (mode.endsWith('refusal')) {
            m.onDeclined?.call('not accepted');
            return;
          }
          committed++;
        }();
      }

      final service = MailboxService(
        client: client,
        me: me,
        orchestrator: orch,
        deliver: deliver,
        drainInterval: const Duration(days: 1),
      );
      MailboxService? retry;

      try {
        Future<void> stash(int n) => orch.stash(
          me: peer,
          recipient: me,
          appId: Uint8List(32),
          endpointId: 1,
          data: Uint8List.fromList([n]),
          contentId: Uint8List(32)..fillRange(0, 32, n),
        );
        await stash(1);
        if (mode == 'failure-then-success') await stash(2);
        await service.start(relays: [_id(7)]);
        await entered.future;
        await orch.finished.future;
        if (mode.startsWith('pending-')) {
          // Observe the completed production drain with the app still held.
          // No guessed delay or timing threshold decides the assertion.
          expect(gate.isCompleted, isFalse);
          expect(committed, 0);
        }
        final remaining = await relay.fetch(me: me, authCookie: Uint8List(0));
        expect(remaining, mode == 'success' ? isEmpty : hasLength(1));
        expect(calls, mode == 'failure-then-success' ? 2 : 1);
        expect(
          committed,
          mode == 'success' || mode == 'failure-then-success' ? 1 : 0,
        );
        if (!gate.isCompleted) gate.complete();
        await service.dispose();
        // A late successful completion cannot retroactively authorize an ACK
        // issued at the earlier timeout. Recovery reopens the retained copy.
        if (mode != 'success') {
          expect(
            await relay.fetch(me: me, authCookie: Uint8List(0)),
            hasLength(1),
          );
          final accepted = <int>[];
          final retryOrch = orchestrator();
          retry = MailboxService(
            client: client,
            me: me,
            orchestrator: retryOrch,
            deliver: (m) async => accepted.add(m.payload.single),
            drainInterval: const Duration(days: 1),
          );
          await retry.start(relays: [_id(7)]);
          await retryOrch.finished.future;
          expect(accepted, [1]);
          expect(await relay.fetch(me: me, authCookie: Uint8List(0)), isEmpty);
        }
      } finally {
        if (!gate.isCompleted) gate.complete();
        await service.dispose();
        await retry?.dispose();
        await client.events_.close();
      }
    });
  }
}
