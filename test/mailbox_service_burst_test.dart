import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/state/mailbox_orchestrator.dart';
import 'package:xveil/state/mailbox_service.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// Only the two members MailboxService actually calls are answered; anything
/// else is a genuine noSuchMethod failure so an unexpected call surfaces.
class _FakeClient implements VeilClient {
  final events_ = StreamController<VeilEvent>.broadcast();
  final registeredRelays = <String>[];
  Completer<Uint8List?>? lookupBlock;
  int lookups = 0;
  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString();
    if (name.contains('lookupRelayX25519')) {
      lookups++;
      final block = lookupBlock;
      if (block != null) return block.future;
      return Future<Uint8List?>.value(Uint8List(32));
    }
    if (name.contains('registerRendezvousPublisher')) {
      final id = i.namedArguments[#rendezvousNodeId];
      if (id is Uint8List) {
        registeredRelays.add(
          id.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        );
      }
      return Future<void>.value();
    }
    if (name.contains('events')) return events_.stream;
    return super.noSuchMethod(i);
  }
}

/// Counts drain calls; each returns a scripted queue entry (or empty).
class _FakeOrchestrator implements MailboxOrchestrator {
  int drains = 0;
  final List<List<DrainedMessage>> queued = [];

  @override
  Future<List<DrainedMessage>> drain({
    required NodeId me,
    required Uint8List authCookie,
    required int ourCertVersion,
    required Future<bool> Function(Uint8List contentId) alreadyHave,
    List<NodeId> knownRelays = const [],
    bool Function()? shouldContinue,
  }) async {
    drains++;
    return queued.isEmpty ? const [] : queued.removeAt(0);
  }

  @override
  Future<void> stash({
    required NodeId me,
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
    required Uint8List contentId,
  }) async {}
}

DrainedMessage _mail() => DrainedMessage(
  sender: _id(9),
  contentId: Uint8List(32),
  appId: Uint8List(16),
  endpointId: 1,
  data: Uint8List.fromList([1, 2, 3]),
);

void main() {
  late _FakeOrchestrator orch;
  late MailboxService svc;

  setUp(() {
    orch = _FakeOrchestrator();
    svc =
        MailboxService(
            client: _FakeClient(),
            me: _id(1),
            orchestrator: orch,
            deliver: (_) {},
            drainInterval: const Duration(milliseconds: 100),
          )
          ..hotDrainInterval = const Duration(milliseconds: 10)
          ..hotWindow = const Duration(milliseconds: 250);
  });
  tearDown(() => svc.dispose());

  test('idle drains back off exponentially, noteActivity opens a fast burst '
      'window, and expiry returns to the idle cadence', () async {
    await svc.start(relays: [_id(7)]);

    // Phase 1 — idle: empty drains escalate the back-off, so over 500ms at a
    // 100ms tick only the first drain or two actually run their body.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final idleDrains = orch.drains;
    expect(
      idleDrains,
      lessThanOrEqualTo(3),
      reason: 'idle back-off must suppress most ticks',
    );

    // Phase 2 — activity: the burst window polls every hot tick (10ms) and
    // empty results must NOT escalate while it is open.
    svc.noteActivity();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final burstDrains = orch.drains - idleDrains;
    expect(
      burstDrains,
      greaterThanOrEqualTo(5),
      reason: 'hot window must poll at the fast cadence',
    );

    // Phase 3 — the window expired: cadence falls back to idle + back-off.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final afterExpiry = orch.drains;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      orch.drains - afterExpiry,
      lessThanOrEqualTo(4),
      reason: 'after the window the idle back-off must resume',
    );
  });

  test('drained mail is delivered as a PROVEN sender, not a claimed one', () async {
    // X/V-01. The drain is the one inbound path this app authenticates for
    // itself: `DrainedMessage.sender` is the orchestrator's crypto-verified
    // sender, recovered from the blob's sidecar and confirmed by the
    // auth-deliver signature, never the relay's wire hint. It must say so, or
    // the gates that ask cannot tell it from a frame that named anyone.
    final delivered = <InboundMessage>[];
    final service = MailboxService(
      client: _FakeClient(),
      me: _id(1),
      orchestrator: orch,
      deliver: delivered.add,
      drainInterval: const Duration(milliseconds: 100),
    );
    addTearDown(service.dispose);
    orch.queued.add([_mail()]);
    await service.start(relays: [_id(7)]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(delivered, isNotEmpty, reason: 'nothing was drained at all');
    expect(delivered.first.src, _id(9));
    expect(
      delivered.first.provenance,
      SenderProvenance.signed,
      reason: 'a verified sender reached the app as an unverified claim',
    );
    expect(delivered.first.provenance.isAuthenticated, isTrue);
  });

  test('drained mail re-arms the burst window by itself', () async {
    // First drain (start's immediate tick) returns mail → the service should
    // enter the hot cadence without any explicit activity call.
    orch.queued.add([_mail()]);
    await svc.start(relays: [_id(7)]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      orch.drains,
      greaterThanOrEqualTo(5),
      reason: 'gotMail must open the burst window',
    );
  });

  test('a live frame drains once and does NOT open the burst window', () async {
    // The frames that arrive without anyone doing anything — acks, and the
    // sync beacons another device of this identity emits every few seconds —
    // all land here. Measured on a paired phone they came every ~20 s, so a
    // window armed by them would never close and an idle pair would poll at
    // the burst cadence for as long as both devices were online.
    await svc.start(relays: [_id(7)]);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final before = orch.drains;
    svc.nudgeDrain();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final nudged = orch.drains - before;
    expect(
      nudged,
      greaterThanOrEqualTo(1),
      reason: 'the frame still earns one prompt drain — that is the latency '
          'lever for a dropped live introduce',
    );
    expect(
      nudged,
      lessThan(5),
      reason: 'but not the fast cadence: 20 hot ticks fit in this window',
    );
    // A nudge also leaves the empty-drain streak alone, so the escalation
    // keeps escalating across beacons. Not asserted here: the 2 s nudge
    // debounce puts the several escalation steps it would take to see the
    // difference out of reach of a fast test, and an assertion that passes
    // with the behaviour removed is worse than none. Verified on a device
    // instead — the streak climbs there where it used to be pinned at 1.
  });

  test('a live frame that reveals mail DOES open the window', () async {
    // The evidence-based half of the same rule: heat follows actual mail.
    await svc.start(relays: [_id(7)]);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final before = orch.drains;
    orch.queued.add([_mail()]);
    svc.nudgeDrain();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(orch.drains - before, greaterThanOrEqualTo(5));
  });

  test('a KEM publisher is registered at EVERY resolvable relay candidate '
      '(not just the first) so every ad slot is deposit-capable', () async {
    final client = _FakeClient();
    final svc2 = MailboxService(
      client: client,
      me: _id(1),
      orchestrator: orch,
      deliver: (_) {},
      drainInterval: const Duration(seconds: 30),
    );
    addTearDown(() async {
      await svc2.dispose();
      await client.events_.close();
    });
    await svc2.start(relays: [_id(7), _id(8), _id(9)]);
    expect(client.registeredRelays.toSet(), {
      _id(7).hex,
      _id(8).hex,
      _id(9).hex,
    });
    // Idempotent within the session: no duplicate registrations per relay.
    expect(client.registeredRelays.length, 3);
  });

  test(
    'concurrent starts coalesce and dispose waits for the native lookup',
    () async {
      final client = _FakeClient();
      final lookup = Completer<Uint8List?>();
      client.lookupBlock = lookup;
      final svc2 = MailboxService(
        client: client,
        me: _id(1),
        orchestrator: orch,
        deliver: (_) {},
        drainInterval: const Duration(seconds: 30),
      );
      addTearDown(() async {
        await svc2.dispose();
        await client.events_.close();
      });

      final first = svc2.start(relays: [_id(7)]);
      final repeated = svc2.start(relays: [_id(7)]);
      expect(identical(first, repeated), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(client.lookups, 1);

      var disposed = false;
      final closing = svc2.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      lookup.complete(Uint8List(32));
      await closing;
      await first;
      expect(
        client.registeredRelays,
        isEmpty,
        reason: 'dispose must prevent a late native registration',
      );
    },
  );

  test('a MAILBOX_WAKE event drains immediately (no debounce) and opens the '
      'burst window', () async {
    final client = _FakeClient();
    final svc2 =
        MailboxService(
            client: client,
            me: _id(1),
            orchestrator: orch,
            deliver: (_) {},
            drainInterval: const Duration(
              seconds: 30,
            ), // idle tick out of the way
          )
          ..hotDrainInterval = const Duration(milliseconds: 10)
          ..hotWindow = const Duration(milliseconds: 300);
    addTearDown(() async {
      await svc2.dispose();
      await client.events_.close();
    });
    await svc2.start(relays: [_id(7)]);
    // Let start()'s immediate drain settle into idle back-off.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final before = orch.drains;

    client.events_.add(
      VeilEvent(
        kind: VeilEventKind.mailboxWake,
        rawKind: 5,
        payload: Uint8List(0),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // One immediate drain + the hot cadence that follows.
    expect(
      orch.drains - before,
      greaterThanOrEqualTo(3),
      reason: 'wake must drain now and keep the burst cadence',
    );
  });

  group('the idle cadence and its ceiling', () {
    test('an idle client polls a minute apart, not ten seconds', () {
      // The wake ping delivers; the poll is the net under it. Measured on a
      // live pair: 16 of 16 deposits arrived by ping, and idling cost 4.2
      // drains a minute.
      expect(kIdleDrainInterval, const Duration(seconds: 60));
    });

    test('the back-off ceiling is a TIME, so the interval cannot blow it up',
        () {
      // It used to be a tick count. Raising the interval then multiplied the
      // worst case with it — at 60s a 32-tick back-off is half an hour of
      // undelivered mail, and this poll exists to catch the deposit whose ping
      // was lost.
      //
      // Asserted against the function the service actually calls. The first
      // version of this test recomputed the formula from the two constants and
      // never touched the code — reverting the cap to a tick count failed
      // nothing, which is how that was noticed.
      for (var streak = 1; streak <= 8; streak++) {
        final skips = idleDrainSkips(streak, kIdleDrainInterval);
        expect(
          kIdleDrainInterval * (skips + 1),
          lessThanOrEqualTo(kMaxIdleDrainGap),
          reason: 'streak $streak must not outrun the ceiling',
        );
      }
      expect(
        idleDrainSkips(8, kIdleDrainInterval),
        greaterThan(1),
        reason: 'and it must still back off, not collapse to one tick',
      );
      // The escalation itself survives where the ceiling is not binding.
      expect(
        idleDrainSkips(1, const Duration(seconds: 1)),
        lessThan(idleDrainSkips(4, const Duration(seconds: 1))),
      );
    });

    test('the hot cadence is untouched — a conversation must stay fast', () {
      final service = MailboxService(
        client: _FakeClient(),
        me: _id(1),
        orchestrator: _FakeOrchestrator(),
        deliver: (_) {},
      );
      addTearDown(service.dispose);
      expect(service.hotDrainInterval, const Duration(seconds: 3));
      expect(service.hotWindow, const Duration(minutes: 2));
    });
  });
}
