import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/disappearing_messages.dart';
import 'package:xveil/features/chat/chat_actions.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;

  /// When true, `send` drops the frame on the floor. Models "the live path is
  /// down while the owner changes the setting" — the case the ordering of
  /// apply-then-announce exists for.
  bool deaf = false;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    if (deaf) return;
    peer?._inbound.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('the shared window itself', () {
    // Two people can tap the menu at the same instant. If each simply kept its
    // own choice, one side would delete and the other would not, and the
    // setting would have quietly stopped being the promise it is sold as.
    test('two simultaneous choices converge on ONE window', () {
      const fromA = DisappearingSetting(
        ttlSeconds: 30,
        setAtMs: 1000,
        setBy: 'aaaa',
      );
      const fromB = DisappearingSetting(
        ttlSeconds: 3600,
        setAtMs: 1000,
        setBy: 'bbbb',
      );
      // Both sides run the same comparison over the same pair, so both must
      // land on the same answer regardless of which one they call "held".
      expect(
        DisappearingSetting.winner(fromA, fromB).ttlSeconds,
        DisappearingSetting.winner(fromB, fromA).ttlSeconds,
      );
      expect(DisappearingSetting.winner(fromA, fromB).setBy, 'bbbb');
    });

    test('the later choice wins regardless of who made it', () {
      const older = DisappearingSetting(
        ttlSeconds: 30,
        setAtMs: 1000,
        setBy: 'zzzz',
      );
      const newer = DisappearingSetting(
        ttlSeconds: null,
        setAtMs: 1001,
        setBy: 'aaaa',
      );
      expect(DisappearingSetting.winner(older, newer).setAtMs, 1001);
      expect(DisappearingSetting.winner(newer, older).setAtMs, 1001);
    });

    // The window is measured from the message's ORIGINAL post time. Anything
    // else and an edit — including an automated one — buys the message another
    // full window, forever.
    test('expiry is measured from the post time, and off never expires', () {
      final sent = DateTime.utc(2026, 1, 1, 12);
      const oneHour = DisappearingSetting(
        ttlSeconds: 3600,
        setAtMs: 1,
        setBy: 'a',
      );
      expect(oneHour.hasExpired(sent, sent.add(const Duration(minutes: 59))),
          isFalse);
      expect(oneHour.hasExpired(sent, sent.add(const Duration(hours: 1))),
          isTrue);
      expect(DisappearingSetting.off.hasExpired(sent, DateTime.utc(3000)),
          isFalse);
      expect(DisappearingSetting.off.cutoffAt(sent), isNull);
    });

    // A malformed announcement must leave the conversation on the window it
    // already had. Decoding garbage as "off" would make a corrupt frame — or a
    // deliberately corrupt one — a way to switch somebody's window off.
    test('a malformed or oversized announcement decodes to nothing', () {
      final from = _id(7);
      expect(
        DisappearingSetting.fromWireJson({'ttl': 'soon', 'ts': 1}, from),
        isNull,
      );
      expect(
        DisappearingSetting.fromWireJson({'ttl': 60}, from),
        isNull,
        reason: 'without a stamp there is nothing to converge on',
      );
      expect(
        DisappearingSetting.fromWireJson({'ttl': -1, 'ts': 1}, from),
        isNull,
      );
      expect(
        DisappearingSetting.fromWireJson(
          {'ttl': kDisappearingMaxSeconds + 1, 'ts': 1},
          from,
        ),
        isNull,
        reason: 'an unbounded window overflows every expiry sum downstream',
      );
      final ok = DisappearingSetting.fromWireJson(
        {'ttl': kDisappearingMaxSeconds, 'ts': 5},
        from,
      );
      expect(ok!.ttlSeconds, kDisappearingMaxSeconds);
      expect(
        ok.setBy,
        from.hex,
        reason: 'the setter is the envelope sender, never a field in the body',
      );
    });

    // The stored body is a token. Any screen that prints message bodies without
    // asking what they are will show `sys:disappearing:3600` to the user — the
    // chat list did exactly that until this helper existed.
    test('no window a user can pick renders as its raw token', () {
      final l = lookupAppL10n(const Locale('en'));
      for (final secs in [0, ...kDisappearingPresets]) {
        final shown = disappearingPreview(l, '$kDisappearingMarkerPrefix$secs');
        expect(shown, isNotNull, reason: 'no notice text for $secs');
        expect(
          shown,
          isNot(contains(kDisappearingMarkerPrefix)),
          reason: 'the token leaked into what the user reads',
        );
      }
      expect(
        disappearingPreview(l, 'an ordinary message'),
        isNull,
        reason: 'a real message must keep rendering as itself',
      );
      // Off is its own sentence, not a window of length zero. Falling through
      // to the formatter renders "0 d", which reads as a window so short that
      // everything vanishes — the opposite of what was chosen.
      expect(
        disappearingPreview(l, '${kDisappearingMarkerPrefix}0'),
        l.chatDisappearingOffNotice,
      );
    });

    test('every preset the menu offers is one the wire accepts', () {
      for (final secs in kDisappearingPresets) {
        expect(
          DisappearingSetting.fromWireJson({'ttl': secs, 'ts': 1}, _id(1)),
          isNotNull,
          reason: 'preset $secs would be refused by the receiver',
        );
      }
    });
  });

  group('two devices', () {
    late NodeId a, b;
    late _FakeTransport tA, tB;
    late HiddenVolumeStorage sA, sB;
    late MessagingService mA, mB;

    setUp(() async {
      a = _id(1);
      b = _id(2);
      tA = _FakeTransport(a);
      tB = _FakeTransport(b);
      tA.peer = tB;
      tB.peer = tA;
      sA = HiddenVolumeStorage(_memOpener());
      sB = HiddenVolumeStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      mA = MessagingService(tA, sA)..start();
      mB = MessagingService(tB, sB)..start();
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();
    });

    tearDown(() async {
      await tA.dispose();
      await tB.dispose();
    });

    // The whole point of the feature: the copy on the OTHER device goes too.
    test('a window chosen here applies on the peer', () async {
      await mA.setContactDisappearing(b, 3600);
      await _pump();
      expect((await sB.getContact(a))!.disappearingTtlSeconds, 3600);
      expect((await sA.getContact(b))!.disappearingTtlSeconds, 3600);
      expect(
        (await sB.getContact(a))!.disappearingSetBy,
        a.hex,
        reason: 'B has to know WHO set it to resolve the next tie',
      );
    });

    // An announcement can arrive late — the mailbox holds it until the peer is
    // reachable. A late frame carrying an OLD stamp must not undo a newer
    // decision that has already been made here.
    test('a stale announcement does not roll the window back', () async {
      await mB.setContactDisappearing(a, 30);
      await _pump();
      final newerStamp = (await sA.getContact(b))!.disappearingSetAtMs;

      // Replay an announcement stamped strictly before the one A holds.
      await tB.send(
        a,
        WireEnvelope(
          WireKind.disappearingSet,
          '{"v":1,"ttl":86400,"ts":${newerStamp - 5000}}',
          sentAtMs: newerStamp - 5000,
        ).withFrameId('replay:1').encode(),
      );
      await _pump();
      expect(
        (await sA.getContact(b))!.disappearingTtlSeconds,
        30,
        reason: 'the older stamp must lose to the one already held',
      );
    });

    // The gate that matters is not "is this node known" — an unknown node is
    // already refused because there is no contact record to write. It is a
    // peer that EXISTS but has not been accepted: a pending request must not
    // be able to set a window that starts erasing this side's history.
    test('a pending, not-yet-accepted peer cannot set the window', () async {
      final c = _id(3);
      // One-way link: C's frames reach A, and A's replies go nowhere. This
      // test is about what A accepts, and leaving A pointed at B keeps the
      // fixture honest about which conversation is which.
      final tC = _FakeTransport(c)..peer = tA;
      final sC = HiddenVolumeStorage(_memOpener());
      await sC.open(password: 'c', createIfMissing: true);
      final mC = MessagingService(tC, sC);
      await mC.sendRequest(a, 'let me in');
      await _pump();
      expect((await sA.getContact(c))!.status, ContactStatus.pendingIncoming);

      await tC.send(
        a,
        WireEnvelope(
          WireKind.disappearingSet,
          '{"v":1,"ttl":30,"ts":9999999999}',
          sentAtMs: 9999999999,
        ).withFrameId('pending:1').encode(),
      );
      await _pump();
      expect(
        (await sA.getContact(c))!.disappearingTtlSeconds,
        isNull,
        reason: 'consent comes first: no acceptance, no shared window',
      );
      await tC.dispose();
    });

    // A notice the owner deleted must stay deleted. The event log folds by
    // message id, so a plain replay is already harmless — this is the case the
    // fold does NOT cover, and it is the one a mailbox re-delivery produces.
    test('a replay does not resurrect a notice the owner deleted', () async {
      await mA.setContactDisappearing(b, 3600);
      await _pump();
      final stamp = (await sB.getContact(a))!.disappearingSetAtMs;
      final noticeId = 'sys:disap:$stamp:${a.hex}';
      await sB.deleteMessage(a.hex, noticeId);
      expect(
        (await sB.loadMessages(a.hex))
            .where((m) => disappearingMarkerSeconds(m.body) != null)
            .length,
        0,
      );

      await tA.send(
        b,
        WireEnvelope(
          WireKind.disappearingSet,
          '{"v":1,"ttl":3600,"ts":$stamp}',
          sentAtMs: stamp,
        ).withFrameId('replay:3').encode(),
      );
      await _pump();
      expect(
        (await sB.loadMessages(a.hex))
            .where((m) => disappearingMarkerSeconds(m.body) != null)
            .length,
        0,
        reason: 'a re-delivered announcement must not undo a deletion',
      );
    });

    // A stranger setting the window would be a way to erase a conversation
    // nobody agreed to have with them.
    test('an announcement from a non-contact is ignored', () async {
      final stranger = _FakeTransport(_id(9))..peer = tA;
      await stranger.send(
        a,
        WireEnvelope(
          WireKind.disappearingSet,
          '{"v":1,"ttl":30,"ts":9999999}',
          sentAtMs: 9999999,
        ).withFrameId('stranger:1').encode(),
      );
      await _pump();
      expect(await sA.getContact(_id(9)), isNull);
      expect((await sA.getContact(b))!.disappearingTtlSeconds, isNull);
      await stranger.dispose();
    });

    // The owner asked for a window. A network that happens to be down at that
    // moment must not leave them with no window at all — the peer catches up
    // on the next announcement, but this device honours the choice now.
    test('the choice applies here even when the announcement cannot go out',
        () async {
      tA.deaf = true;
      await mA.setContactDisappearing(b, 30);
      await _pump();
      expect((await sA.getContact(b))!.disappearingTtlSeconds, 30);
      expect((await sB.getContact(a))!.disappearingTtlSeconds, isNull);
    });

    // The sweep is the part that actually deletes. It must take what has run
    // out of time and nothing else.
    test('the sweep removes what expired and keeps what did not', () async {
      await mA.sendText(b, 'old enough to go');
      await _pump();
      // Backdate the stored message by an hour by choosing a window shorter
      // than its age rather than by editing the row: the arithmetic under test
      // is "post time + window vs now", and rewriting the row would test the
      // rewrite instead.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await mA.sendText(b, 'just now');
      await _pump();
      expect((await sA.loadMessages(b.hex)).length, greaterThanOrEqualTo(2));

      // A one-second window: the first message is already past it, the second
      // is not.
      await mA.setContactDisappearing(b, 1);
      await _pump();
      final left = (await sA.loadMessages(b.hex)).map((m) => m.body).toList();
      expect(left, isNot(contains('old enough to go')));
      expect(left, contains('just now'));
    });

    // The change is a row in the timeline on BOTH sides: a window that governs
    // what the other person's device deletes is not something either of them
    // should have to discover by noticing an absence.
    test('both sides get a visible notice, and a replay does not double it',
        () async {
      await mA.setContactDisappearing(b, 3600);
      await _pump();
      int notices(List<Message> ms) => ms
          .where((m) => disappearingMarkerSeconds(m.body) != null)
          .length;
      expect(notices(await sA.loadMessages(b.hex)), 1);
      expect(notices(await sB.loadMessages(a.hex)), 1);

      // Re-deliver the very same announcement: the sender's durable copy sits
      // in the mailbox until acked, and a restart clears the RAM seen-set.
      final stamp = (await sB.getContact(a))!.disappearingSetAtMs;
      await tA.send(
        b,
        WireEnvelope(
          WireKind.disappearingSet,
          '{"v":1,"ttl":3600,"ts":$stamp}',
          sentAtMs: stamp,
        ).withFrameId('replay:2').encode(),
      );
      await _pump();
      expect(
        notices(await sB.loadMessages(a.hex)),
        1,
        reason: 'a re-delivered announcement must not mint a second notice',
      );
    });
  });
}
