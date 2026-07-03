import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/mailbox_orchestrator.dart';
import 'package:xveil/state/mailbox_service.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

/// Only the two members MailboxService actually calls are answered; anything
/// else is a genuine noSuchMethod failure so an unexpected call surfaces.
class _FakeClient implements VeilClient {
  final events_ = StreamController<VeilEvent>.broadcast();
  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString();
    if (name.contains('lookupRelayX25519')) {
      return Future<Uint8List?>.value(Uint8List(32));
    }
    if (name.contains('registerRendezvousPublisher')) {
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
    svc = MailboxService(
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

  test(
      'idle drains back off exponentially, noteActivity opens a fast burst '
      'window, and expiry returns to the idle cadence', () async {
    await svc.start(relays: [_id(7)]);

    // Phase 1 — idle: empty drains escalate the back-off, so over 500ms at a
    // 100ms tick only the first drain or two actually run their body.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final idleDrains = orch.drains;
    expect(idleDrains, lessThanOrEqualTo(3),
        reason: 'idle back-off must suppress most ticks');

    // Phase 2 — activity: the burst window polls every hot tick (10ms) and
    // empty results must NOT escalate while it is open.
    svc.noteActivity();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final burstDrains = orch.drains - idleDrains;
    expect(burstDrains, greaterThanOrEqualTo(5),
        reason: 'hot window must poll at the fast cadence');

    // Phase 3 — the window expired: cadence falls back to idle + back-off.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final afterExpiry = orch.drains;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(orch.drains - afterExpiry, lessThanOrEqualTo(4),
        reason: 'after the window the idle back-off must resume');
  });

  test('drained mail re-arms the burst window by itself', () async {
    // First drain (start's immediate tick) returns mail → the service should
    // enter the hot cadence without any explicit activity call.
    orch.queued.add([_mail()]);
    await svc.start(relays: [_id(7)]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(orch.drains, greaterThanOrEqualTo(5),
        reason: 'gotMail must open the burst window');
  });

  test('nudgeDrain opens the burst window too', () async {
    await svc.start(relays: [_id(7)]);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final before = orch.drains;
    svc.nudgeDrain();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(orch.drains - before, greaterThanOrEqualTo(5));
  });

  test('a MAILBOX_WAKE event drains immediately (no debounce) and opens the '
      'burst window', () async {
    final client = _FakeClient();
    final svc2 = MailboxService(
      client: client,
      me: _id(1),
      orchestrator: orch,
      deliver: (_) {},
      drainInterval: const Duration(seconds: 30), // idle tick out of the way
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
    expect(orch.drains - before, greaterThanOrEqualTo(3),
        reason: 'wake must drain now and keep the burst cadence');
  });
}
