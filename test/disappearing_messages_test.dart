import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xveil/state/providers.dart';
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
  _readClockTests();
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
      expect(
        oneHour.hasExpired(sent, sent.add(const Duration(minutes: 59))),
        isFalse,
      );
      expect(
        oneHour.hasExpired(sent, sent.add(const Duration(hours: 1))),
        isTrue,
      );
      expect(
        DisappearingSetting.off.hasExpired(sent, DateTime.utc(3000)),
        isFalse,
      );
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
        DisappearingSetting.fromWireJson({
          'ttl': kDisappearingMaxSeconds + 1,
          'ts': 1,
        }, from),
        isNull,
        reason: 'an unbounded window overflows every expiry sum downstream',
      );
      final ok = DisappearingSetting.fromWireJson({
        'ttl': kDisappearingMaxSeconds,
        'ts': 5,
      }, from);
      expect(ok!.ttlSeconds, kDisappearingMaxSeconds);
      expect(
        ok.setBy,
        from.hex,
        reason: 'the setter is the envelope sender, never a field in the body',
      );
    });

    /// `winner` is last-writer-wins on `ts`, so a stamp in the far future is
    /// not an odd value in a record — it is a permanent victory. An
    /// authenticated contact could announce `ttl = 1` dated years ahead: the
    /// sweep starts deleting the conversation at once, and every honest update
    /// afterwards LOSES the comparison for as long as the claim says. A Space
    /// already refuses exactly this; the direct path is the half that did not.
    test('a stamp our clock could not have produced is refused', () {
      final from = _id(11);
      final now = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);

      expect(
        DisappearingSetting.fromWireJson(
          {'ttl': 1, 'ts': now.millisecondsSinceEpoch + 365 * 86400 * 1000},
          from,
          now: now,
        ),
        isNull,
        reason: 'a year ahead is a claim no clock here could have made',
      );
      expect(
        DisappearingSetting.fromWireJson(
          {'ttl': 1, 'ts': 9223372036854775807},
          from,
          now: now,
        ),
        isNull,
        reason: 'and the extreme that used to throw building a DateTime',
      );

      // Inside the tolerance, and in the past, both stay honoured: a device
      // back from a week offline must keep last Tuesday's setting, and an early
      // stamp can only expire less.
      final skewed = DisappearingSetting.fromWireJson(
        {
          'ttl': 60,
          'ts':
              now.millisecondsSinceEpoch +
              kDisappearingClockSkew.inMilliseconds -
              1000,
        },
        from,
        now: now,
      );
      expect(
        skewed,
        isNotNull,
        reason: 'ordinary clock drift is not an attack',
      );

      final past = DisappearingSetting.fromWireJson(
        {'ttl': 60, 'ts': now.millisecondsSinceEpoch - 7 * 86400 * 1000},
        from,
        now: now,
      );
      expect(past, isNotNull);
      expect(past!.ttlSeconds, 60);
    });

    /// Refusal must leave the conversation on the window it already had —
    /// the same contract the parser keeps for anything else it cannot believe.
    test('a refused stamp cannot displace the setting in force', () {
      final from = _id(12);
      final now = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
      final held = DisappearingSetting(
        ttlSeconds: 3600,
        setAtMs: now.millisecondsSinceEpoch - 1000,
        setBy: from.hex,
      );

      final hostile = DisappearingSetting.fromWireJson(
        {'ttl': 1, 'ts': now.millisecondsSinceEpoch + 10 * 365 * 86400 * 1000},
        from,
        now: now,
      );
      expect(hostile, isNull);

      // Nothing to feed `winner`, so the held window stands.
      expect(held.ttlSeconds, 3600);
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

  /// The bookkeeping behind the read window: what this device has SHOWN, and
  /// when. Driven through the real read marker rather than a test hook, because
  /// the whole design rests on that marker being the monotone quantity.
  group('shown bookkeeping', () {
    late NodeId a, b;
    late _FakeTransport tA, tB;
    late HiddenVolumeStorage sA, sB;
    late MessagingService mA, mB;
    late DateTime clockA, clockB;

    setUp(() async {
      a = _id(1);
      b = _id(2);
      // Anchored to the REAL clock, not to a round number in the past. The
      // storage stamps rows with its own `DateTime.now`, and the read marker
      // rises to the newest of them — so a fixture set three years back leaves
      // the marker permanently ahead of the injected clock, the future-clamp
      // trims coverage to "now" on every visit, and the record grows one entry
      // per visit instead of staying still. The first version of this group did
      // exactly that and reported the bookkeeping as broken.
      clockA = DateTime.now();
      clockB = clockA;
      tA = _FakeTransport(a);
      tB = _FakeTransport(b);
      tA.peer = tB;
      tB.peer = tA;
      sA = HiddenVolumeStorage(_memOpener());
      sB = HiddenVolumeStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      mA = MessagingService(tA, sA, now: () => clockA)..start();
      mB = MessagingService(tB, sB, now: () => clockB)..start();
      await mA.sendRequest(b, 'hi');
      await _pump();
      await mB.acceptContact(a);
      await _pump();
      await mA.setContactHideAfterRead(b, 300);
      await _pump();
    });

    tearDown(() async {
      await tA.dispose();
      await tB.dispose();
    });

    test('nothing is hidden before the window passes', () async {
      clockB = clockB.add(const Duration(seconds: 1));
      await mB.sendText(a, 'hello');
      await _pump();
      clockA = clockA.add(const Duration(seconds: 2));
      await mA.markRead(b.hex);

      expect(await mA.hiddenThroughTs(b), 0);
      clockA = clockA.add(const Duration(seconds: 299));
      expect(await mA.hiddenThroughTs(b), 0);
    });

    test('what was shown is hidden once its window passes', () async {
      clockB = clockB.add(const Duration(seconds: 1));
      await mB.sendText(a, 'hello');
      await _pump();
      final sentAt = (await sA.loadMessages(b.hex)).last.timestamp;
      clockA = clockA.add(const Duration(seconds: 2));
      await mA.markRead(b.hex);

      clockA = clockA.add(const Duration(seconds: 300));
      final through = await mA.hiddenThroughTs(b);
      expect(through, greaterThanOrEqualTo(sentAt.millisecondsSinceEpoch));
    });

    /// The clock the marker rides on is the SENDER's, and the marker rises to
    /// the newest message. Uncapped, one message dated to the next century
    /// would cover the whole conversation with a single showing event and take
    /// the entire history down with it once the window passed.
    ///
    /// The hostile row is written STRAIGHT into A's store. Sending it from B
    /// with B's clock wound forward does not reach A at all — the first version
    /// of this test did that, no future-dated row ever landed, and it passed
    /// while testing nothing.
    test('a message dated in the future does not hide the history', () async {
      clockB = clockB.add(const Duration(seconds: 1));
      await mB.sendText(a, 'honest');
      await _pump();
      final honestAt = (await sA.loadMessages(b.hex)).last.timestamp;

      // Whole milliseconds: the store keeps ms, so a DateTime carrying
      // microseconds never compares equal to what comes back out.
      final hostileAt = DateTime.fromMillisecondsSinceEpoch(
        clockA.add(const Duration(days: 365 * 80)).millisecondsSinceEpoch,
      );
      await sA.appendMessage(
        Message(
          id: 'hostile-row',
          conversationId: b.hex,
          direction: MessageDirection.incoming,
          body: 'from the year 2105',
          timestamp: hostileAt,
          author: b.hex,
        ),
      );
      expect(
        (await sA.loadMessages(
          b.hex,
        )).map((m) => m.timestamp.millisecondsSinceEpoch).toList(),
        contains(hostileAt.millisecondsSinceEpoch),
        reason: 'the row this test is about must actually be in the store',
      );

      clockA = clockA.add(const Duration(seconds: 2));
      await mA.markRead(b.hex);
      expect(
        await sA.readMarker(b.hex),
        hostileAt.millisecondsSinceEpoch,
        reason: 'and the marker must really have been dragged to 2105',
      );

      clockA = clockA.add(const Duration(seconds: 400));
      final through = await mA.hiddenThroughTs(b);
      expect(
        through,
        greaterThanOrEqualTo(honestAt.millisecondsSinceEpoch),
        reason: 'the honest message was shown and its window passed',
      );
      expect(
        through,
        lessThan(hostileAt.millisecondsSinceEpoch),
        reason:
            'coverage stops at our own clock, so the future-dated row '
            'cannot drag the history with it',
      );
    });

    /// Re-opening a chat must not restart the clock, or a window would only
    /// ever elapse for someone who never looked at the conversation again.
    test('the first showing wins over later ones', () async {
      clockB = clockB.add(const Duration(seconds: 1));
      await mB.sendText(a, 'hello');
      await _pump();
      clockA = clockA.add(const Duration(seconds: 2));
      await mA.markRead(b.hex);

      final firstShownAt =
          ((jsonDecode((await sA.getSetting('disap.shown.v1:${b.hex}'))!)
                      as Map)['e']
                  as List)
              .single[1];

      // Four more visits, no new messages.
      for (var i = 0; i < 4; i++) {
        clockA = clockA.add(const Duration(seconds: 60));
        await mA.markRead(b.hex);
      }

      // Asserted on the RECORD, not on the outcome. Phrased as "and it is
      // hidden by now", a break that refreshed the moment on every visit still
      // passed, because by then enough total time had gone by for the refreshed
      // moment to expire too.
      expect(
        ((jsonDecode((await sA.getSetting('disap.shown.v1:${b.hex}'))!)
                    as Map)['e']
                as List)
            .single[1],
        firstShownAt,
        reason: 'the moment must be the FIRST showing, not the latest visit',
      );

      // 302s after the first showing; the last visit was 62s ago.
      clockA = clockA.add(const Duration(seconds: 60));
      expect(await mA.hiddenThroughTs(b), greaterThan(0));
    });

    test('a window turned off hides nothing', () async {
      clockB = clockB.add(const Duration(seconds: 1));
      await mB.sendText(a, 'hello');
      await _pump();
      clockA = clockA.add(const Duration(seconds: 2));
      await mA.markRead(b.hex);

      // Let the showing EXPIRE and collapse into the mark first. Turning the
      // window off while the mark was still zero proved nothing: an answer
      // that ignored the setting entirely returned zero too.
      clockA = clockA.add(const Duration(seconds: 400));
      expect(await mA.hiddenThroughTs(b), greaterThan(0));

      await mA.setContactHideAfterRead(b, null);
      await _pump();
      clockA = clockA.add(const Duration(days: 30));
      expect(
        await mA.hiddenThroughTs(b),
        0,
        reason: 'off means nothing is hidden, mark or no mark',
      );
    });

    /// The bookkeeping is only worth having if it reaches the screen. The
    /// list the chat renders comes from a provider, so this drives that
    /// provider rather than the service method it calls — a mark that moves
    /// while the filter ignores it looks exactly like a working feature.
    test('what is hidden stops reaching the chat list', () async {
      clockB = clockB.add(const Duration(seconds: 1));
      await mB.sendText(a, 'early');
      await _pump();
      clockA = clockA.add(const Duration(seconds: 2));
      await mA.markRead(b.hex);

      final container = ProviderContainer(
        overrides: [
          messagingServiceProvider.overrideWithValue(mA),
          storageProvider.overrideWithValue(sA),
        ],
      );
      addTearDown(container.dispose);

      // The provider is autoDispose: reading its future without a live
      // listener disposes it mid-load and the read never completes.
      final keepAlive = container.listen(
        messagesProvider(b.hex),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(keepAlive.close);

      Future<List<String>> bodies() async => (await container.read(
        messagesProvider(b.hex).future,
      )).map((m) => m.body).toList();

      expect(await bodies(), contains('early'));

      clockA = clockA.add(const Duration(seconds: 400));
      container.invalidate(messagesProvider(b.hex));
      expect(
        await bodies(),
        isNot(contains('early')),
        reason: 'the mark moved past it, so the list must stop carrying it',
      );

      // A message that arrives AFTER the showing was never on screen, so the
      // same mark must not swallow it.
      clockB = clockA.add(const Duration(seconds: 1));
      await mB.sendText(a, 'later');
      await _pump();
      container.invalidate(messagesProvider(b.hex));
      expect(await bodies(), contains('later'));
    });

    /// It runs on the chat's timer, which keeps firing while a screen tears
    /// down and the container closes under it. An exception out of a timer is
    /// not a recoverable state for the widget tree above it.
    test('a locked store answers zero instead of throwing', () async {
      clockB = clockB.add(const Duration(seconds: 1));
      await mB.sendText(a, 'hello');
      await _pump();
      clockA = clockA.add(const Duration(seconds: 2));
      await mA.markRead(b.hex);
      clockA = clockA.add(const Duration(seconds: 400));
      expect(await mA.hiddenThroughTs(b), greaterThan(0));

      await sA.close();
      expect(await mA.hiddenThroughTs(b), 0);
    });

    /// The point of the whole shape: the record does not grow with the
    /// conversation. Once a showing's window has passed it becomes one integer.
    test('the record collapses instead of growing', () async {
      for (var i = 0; i < 40; i++) {
        clockB = clockB.add(const Duration(seconds: 10));
        await mB.sendText(a, 'm$i');
        await _pump();
        clockA = clockB.add(const Duration(seconds: 1));
        await mA.markRead(b.hex);
      }
      clockA = clockA.add(const Duration(seconds: 400));
      await mA.hiddenThroughTs(b);

      final raw = await sA.getSetting('disap.shown.v1:${b.hex}');
      final decoded = jsonDecode(raw!) as Map;
      expect(
        (decoded['e'] as List),
        isEmpty,
        reason: 'every showing older than the window folded into the mark',
      );
      expect(decoded['w'], greaterThan(0));
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

    /// Renaming a contact used to turn their disappearing messages OFF.
    ///
    /// `setContactName` and `setContactRetention` each rebuilt the whole
    /// Contact from a hand-written field list, and those lists predated the
    /// disappearing window. Nothing announced the erasure as an erasure — the
    /// next announcement simply carried "off" as a fresh decision, and the
    /// peer adopted it.
    test('renaming a contact does not clear their window', () async {
      await mA.setContactDisappearing(b, 3600);
      await mA.setContactHideAfterRead(b, 300);
      await _pump();

      await mA.setContactName(b, 'Bo');
      await mA.setContactRetention(b, 30);

      final held = await sA.getContact(b);
      expect(held!.name, 'Bo');
      expect(held.retentionDays, 30);
      expect(held.disappearingTtlSeconds, 3600);
      expect(held.hideAfterReadSeconds, 300);
      expect(held.disappearingSetBy, a.hex, reason: 'and who set it survives');
    });

    /// Two halves, one announcement. Setting either must not silently clear
    /// the other — locally or on the peer, which adopts whatever arrives.
    test('the two clocks do not overwrite each other', () async {
      await mA.setContactDisappearing(b, 3600);
      await _pump();
      await mA.setContactHideAfterRead(b, 300);
      await _pump();

      expect((await sA.getContact(b))!.disappearingTtlSeconds, 3600);
      expect((await sA.getContact(b))!.hideAfterReadSeconds, 300);
      expect((await sB.getContact(a))!.disappearingTtlSeconds, 3600);
      expect(
        (await sB.getContact(a))!.hideAfterReadSeconds,
        300,
        reason: 'the peer adopts both halves from the one v2 frame',
      );

      // And turning one off leaves the other standing.
      await mA.setContactHideAfterRead(b, null);
      await _pump();
      expect((await sA.getContact(b))!.disappearingTtlSeconds, 3600);
      expect((await sA.getContact(b))!.hideAfterReadSeconds, isNull);
      expect((await sB.getContact(a))!.disappearingTtlSeconds, 3600);
      expect((await sB.getContact(a))!.hideAfterReadSeconds, isNull);

      // The OTHER order too. Both directions matter and only one of them was
      // covered: a break that made `setContactDisappearing` drop the read half
      // passed cleanly, because every assertion above set the read half last.
      await mA.setContactHideAfterRead(b, 120);
      await _pump();
      await mA.setContactDisappearing(b, 60);
      await _pump();
      expect(
        (await sA.getContact(b))!.hideAfterReadSeconds,
        120,
        reason: 'changing the post-time half must not clear the read half',
      );
      expect((await sB.getContact(a))!.hideAfterReadSeconds, 120);
      expect((await sA.getContact(b))!.disappearingTtlSeconds, 60);
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
        (await sB.loadMessages(
          a.hex,
        )).where((m) => disappearingMarkerSeconds(m.body) != null).length,
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
        (await sB.loadMessages(
          a.hex,
        )).where((m) => disappearingMarkerSeconds(m.body) != null).length,
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
    test(
      'the choice applies here even when the announcement cannot go out',
      () async {
        tA.deaf = true;
        await mA.setContactDisappearing(b, 30);
        await _pump();
        expect((await sA.getContact(b))!.disappearingTtlSeconds, 30);
        expect((await sB.getContact(a))!.disappearingTtlSeconds, isNull);
      },
    );

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
    test(
      'both sides get a visible notice, and a replay does not double it',
      () async {
        await mA.setContactDisappearing(b, 3600);
        await _pump();
        int notices(List<Message> ms) =>
            ms.where((m) => disappearingMarkerSeconds(m.body) != null).length;
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
      },
    );
  });
}

/// The READ clock: a second window on the same setting, with a different
/// promise. These pin the model; the bookkeeping that records when a device
/// first showed a message is a separate piece.
void _readClockTests() {
  group('hide after read', () {
    const setting = DisappearingSetting(
      ttlSeconds: null,
      setAtMs: 1000,
      setBy: 'aa',
      hideAfterReadSeconds: 300,
    );
    final t0 = DateTime.fromMillisecondsSinceEpoch(2000000);

    test('a message never shown is never hidden by this rule', () {
      expect(
        setting.isHiddenAfterRead(null, t0.add(const Duration(days: 365))),
        isFalse,
        reason: 'the whole difference from the post-time window is right here',
      );
    });

    test('the boundary is exact and inclusive', () {
      expect(
        setting.isHiddenAfterRead(t0, t0.add(const Duration(seconds: 299))),
        isFalse,
      );
      expect(
        setting.isHiddenAfterRead(t0, t0.add(const Duration(seconds: 300))),
        isTrue,
      );
    });

    test('off means never hidden, however long ago it was shown', () {
      const off = DisappearingSetting(
        ttlSeconds: 60,
        setAtMs: 1000,
        setBy: 'aa',
      );
      expect(off.hidesAfterRead, isFalse);
      expect(
        off.isHiddenAfterRead(t0, t0.add(const Duration(days: 365))),
        isFalse,
      );
    });

    /// v1 readers must keep working, and the half they cannot carry is the
    /// courtesy one — never the guarantee.
    test('only a read window makes the announcement v2', () {
      expect(
        const DisappearingSetting(
          ttlSeconds: 60,
          setAtMs: 1,
          setBy: 'aa',
        ).toWireJson()['v'],
        1,
      );
      final json = setting.toWireJson();
      expect(json['v'], 2);
      expect(json['rttl'], 300);
      expect(json['ttl'], 0, reason: 'the post-time half is still carried');
    });

    test('a v1 announcement decodes with no read window', () {
      final decoded = DisappearingSetting.fromWireJson({
        'v': 1,
        'ttl': 60,
        'ts': 5,
      }, NodeId(Uint8List.fromList(List.filled(32, 3))));
      expect(decoded?.ttlSeconds, 60);
      expect(decoded?.hideAfterReadSeconds, isNull);
    });

    test('a v2 announcement round-trips both halves', () {
      final decoded = DisappearingSetting.fromWireJson(
        setting.toWireJson().cast<String, Object?>(),
        NodeId(Uint8List.fromList(List.filled(32, 3))),
      );
      expect(decoded?.hideAfterReadSeconds, 300);
    });

    /// The same rule the post-time half already follows: a garbled field
    /// rejects the whole announcement rather than falling back to "off",
    /// or a peer could clear someone's window by sending nonsense.
    test('a malformed read window rejects the announcement', () {
      final from = NodeId(Uint8List.fromList(List.filled(32, 3)));
      for (final bad in <Object>['soon', 0, -1, kDisappearingMaxSeconds + 1]) {
        expect(
          DisappearingSetting.fromWireJson({
            'v': 2,
            'ttl': 60,
            'ts': 5,
            'rttl': bad,
          }, from),
          isNull,
          reason: 'rttl=$bad must not silently become "off"',
        );
      }
    });
  });
}
