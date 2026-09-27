import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/chat/held_while_blocked_banner.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

class _Capture implements VeilTransport {
  _Capture(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  final sent = <(NodeId, WireKind)>[];
  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async =>
      sent.add((dst, WireEnvelope.decode(payload).kind));
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

void main() {
  // A message from a blocked contact was dropped unacked, re-driven by its
  // sender, and appeared the moment the block was lifted. Owner's decision
  // (2026-09-27): keep it aside, acknowledge it, and let the person choose.
  final peer = _id(0x44);
  late HiddenVolumeStorage storage;
  late _Capture t;
  late MessagingService m;
  var nextSeq = 0;

  setUp(() async {
    nextSeq = 0;
    final store = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => store,
    );
    await storage.open(password: 'pw', createIfMissing: true);
    t = _Capture(_id(1));
    m = MessagingService(t, storage)..start();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.blocked),
    );
  });
  tearDown(() => m.dispose());

  Future<void> arrive(String id) async {
    nextSeq++;
    await m.deliverInbound(
      InboundMessage(
        src: peer,
        payload: WireEnvelope.message(
          'text $id',
          id: id,
          sentAtMs: DateTime.now().millisecondsSinceEpoch,
          seq: nextSeq,
        ).encode(),
        provenance: SenderProvenance.signed,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('held aside and acknowledged, not shown', () async {
    await arrive('m1');
    expect(await storage.loadMessageById(peer.hex, 'm1'), isNull,
        reason: 'a blocked contact reached the chat');
    expect(await m.heldWhileBlocked(peer), 1);
    expect(t.sent.where((e) => e.$2 == WireKind.ack), isNotEmpty,
        reason: 'unacked, the sender re-sends it until the block lifts');
    expect((await storage.conversationSync(peer.hex)).highWater[peer.hex], 1,
        reason: 'a hole at its seq: gap-fill re-sends it into the chat the '
            'moment the block is lifted');
  });

  test('after unblocking, shown only when asked', () async {
    await arrive('m1');
    await arrive('m2');
    await m.unblockContact(peer);
    expect(await storage.loadMessageById(peer.hex, 'm1'), isNull,
        reason: 'unblocking alone must not show them');
    expect(await m.releaseHeldWhileBlocked(peer), 2);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await storage.loadMessageById(peer.hex, 'm1'), isNotNull);
    expect(await storage.loadMessageById(peer.hex, 'm2'), isNotNull);
    expect(await m.heldWhileBlocked(peer), 0);
  });

  test('or deleted unread', () async {
    await arrive('m1');
    await m.unblockContact(peer);
    await m.discardHeldWhileBlocked(peer);
    expect(await m.heldWhileBlocked(peer), 0);
    expect(await storage.loadMessageById(peer.hex, 'm1'), isNull);
  });

  test('not shown while still blocked, even if asked', () async {
    await arrive('m1');
    expect(await m.releaseHeldWhileBlocked(peer), 0);
    expect(await storage.loadMessageById(peer.hex, 'm1'), isNull);
  });

  testWidgets('the chat offers to show them, and shows them', (tester) async {
    await tester.runAsync(() async {
      await arrive('m1');
      await m.unblockContact(peer);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [messagingServiceProvider.overrideWithValue(m)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(body: HeldWhileBlockedBanner(peer: peer)),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('held-while-blocked')), findsOneWidget,
        reason: 'the choice was never offered');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('held-show')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.runAsync(() async {
      expect(await storage.loadMessageById(peer.hex, 'm1'), isNotNull);
    });
    expect(find.byKey(const ValueKey('held-while-blocked')), findsNothing);
  });
}
