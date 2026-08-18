@Timeout(Duration(minutes: 40))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';

import 'convergence_oracle.dart';
import 'device_fixture.dart';
import 'e2e_env.dart';

/// The first three cases of the multi-device checklist, run end to end against
/// the REAL stack: real `veilclient-ffi` nodes, a real local relay island, real
/// deniable containers, the app's own providers.
///
/// Every case ends in [convergenceOf]. See `convergence_oracle.dart` for what
/// "agree" means and `convergence_oracle_test.dart` for the proof that the
/// oracle can say no.
///
/// Env-gated — see `test/e2e/README.md`. An ungated `flutter test` skips this
/// file with a message naming the variables.
void main() {
  final gate = E2eGate.read();

  /// The message id of the row whose body is [body] in [device]'s conversation
  /// with [peer]. Fails with the conversation it DID find, because "the message
  /// is not there" is worth exactly as much as the list that is.
  Future<String> idOf(E2eDevice device, NodeId peer, String body) async {
    final rows = await device.conversationRows(peer);
    final match = rows.where((m) => m.body == body).toList();
    if (match.length != 1) {
      fail('${device.label} holds ${match.length} rows with body "$body"; its '
          'conversation with ${peer.short} is '
          '${rows.map((m) => "${m.direction.name}:${m.body}").toList()}');
    }
    return match.single.id;
  }

  Future<void> expectConverged(
    E2eDevice x,
    E2eDevice y, {
    NodeId? conversationPeer,
    bool requireConversationAgreement = false,
    required String what,
  }) async {
    final a = await x.snapshot(conversationPeer: conversationPeer);
    final b = await y.snapshot(conversationPeer: conversationPeer);
    final verdict = convergenceOf(
      a,
      b,
      requireConversationAgreement: requireConversationAgreement,
    );
    expect(
      verdict.agree,
      isTrue,
      reason: '$what\n${verdict.describe()}\n  ${x.label}: $a\n  ${y.label}: $b',
    );
  }

  group('multi-device checklist', () {
    // ---------------------------------------------------------------------
    test(
      'case 3/8 — C writes to identity X while A and B are both up: the '
      'message lands on each of them exactly once',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
        final f = fleet;

        await f.linkDevice(master: f.a, target: f.b);
        await f.introduce(f.c, f.a);

        const body = 'case-3-8 from C to identity X';
        await f.c.messaging.sendText(f.a.identityNodeId, body);

        // A is the device the identity address resolves to; B gets it through
        // the multi-device mirror. Both must end up holding it, and the mirror
        // is the half that has failed here before.
        await waitUntil(
          () async => (await f.a.conversation(f.c.identityNodeId)).contains(body),
          what: 'A to hold C\'s message',
          describe: () async => 'A conv=${await f.a.conversation(f.c.identityNodeId)}',
          timeout: const Duration(minutes: 3),
        );
        await waitUntil(
          () async => (await f.b.conversation(f.c.identityNodeId)).contains(body),
          what: 'B (the sibling) to mirror C\'s message',
          describe: () async =>
              'B conv=${await f.b.conversation(f.c.identityNodeId)}; '
              'A conv=${await f.a.conversation(f.c.identityNodeId)}',
          timeout: const Duration(minutes: 5),
        );

        final messageId = await idOf(f.a, f.c.identityNodeId, body);
        final onA = await f.a.snapshot(conversationPeer: f.c.identityNodeId);
        final onB = await f.b.snapshot(conversationPeer: f.c.identityNodeId);

        // EXACTLY once. "It arrived" and "it arrived once" are different
        // claims, and the second is the one this project has had to fix: a row
        // keyed by `msgId ?? contentId` used to land twice under two keys.
        expect(exactlyOnce(onA, messageId), isNull, reason: 'A: $onA');
        expect(exactlyOnce(onB, messageId), isNull, reason: 'B: $onB');

        await expectConverged(
          f.a,
          f.b,
          conversationPeer: f.c.identityNodeId,
          requireConversationAgreement: true,
          what: 'A and B must agree after receiving one message from C',
        );
      },
      skip: gate.skip,
    );

    // ---------------------------------------------------------------------
    test(
      'case 10 — A writes to C while B is down; A and C then go down and B '
      'comes up: B ends holding its identity\'s own outgoing message',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
        final f = fleet;

        await f.linkDevice(master: f.a, target: f.b);
        await f.introduce(f.a, f.c);

        await f.b.stop();

        const body = 'case-10 from A to C while B slept';
        await f.a.messaging.sendText(f.c.identityNodeId, body);

        // Prove it actually left A before taking A down — otherwise a failure
        // at the end cannot be told apart from "the send never happened".
        await waitUntil(
          () async => (await f.c.conversation(f.a.identityNodeId)).contains(body),
          what: 'C to receive A\'s message',
          describe: () async => 'C conv=${await f.c.conversation(f.a.identityNodeId)}',
          timeout: const Duration(minutes: 3),
        );

        // A MUST HAVE DEPOSITED FOR B BEFORE IT DIES. B is asleep, so the
        // mirror can only reach it through the mailbox, and the deposit is
        // asynchronous — taking A down six seconds after the send would test
        // "does an undeposited frame arrive", which is not this case and has
        // only one honest answer. The outbox depth toward B's DEVICE id is the
        // observable, so this is a polled condition and not a sleep.
        final bDevice = f.b.deviceNodeId;
        await waitUntil(
          () async => f.a.messaging.debugPendingFor(bDevice.hex) == 0,
          what: 'A to flush its outbox toward the sleeping sibling B '
              '(otherwise nothing was ever deposited and the case is vacuous)',
          describe: () async =>
              'A outbox→B=${f.a.messaging.debugPendingFor(bDevice.hex)} '
              'A outbox→C=${f.a.messaging.debugPendingFor(f.c.identityNodeId.hex)}',
          timeout: const Duration(minutes: 5),
        );

        await f.a.stop();
        await f.c.stop();
        await f.b.start();

        // Now B is the only device of identity X that is running. The row can
        // only reach it from the mailbox: A is gone, and there is no live leg
        // to anybody. This is the case that fails when the mirror is deposited
        // for nobody, or when the drain never wakes.
        await waitUntil(
          () async => (await f.b.conversation(f.c.identityNodeId)).contains(body),
          what: 'B to drain its identity\'s own outgoing message from the '
              'mailbox with every other device down',
          describe: () async =>
              'B conv=${await f.b.conversation(f.c.identityNodeId)}; '
              'B state=${await f.b.snapshot()}',
          // The campaign measured this cadence at ~260s after the relay-warmup
          // fix, so the deadline is generous on purpose: a tight one would
          // report a slow path as a broken one.
          timeout: const Duration(minutes: 10),
        );

        final rows = await f.b.conversationRows(f.c.identityNodeId);
        final mirrored = rows.singleWhere((m) => m.body == body);
        expect(
          mirrored.direction,
          MessageDirection.outgoing,
          reason: 'the row is the IDENTITY\'s own outgoing message, so it must '
              'arrive on B as outgoing — an incoming copy would show the user '
              'their own words as if a contact had written them',
        );
        final onB = await f.b.snapshot(conversationPeer: f.c.identityNodeId);
        expect(exactlyOnce(onB, mirrored.id), isNull, reason: 'B: $onB');
      },
      skip: gate.skip,
    );

    // ---------------------------------------------------------------------
    test(
      'case 20 — A edits a message while B deletes it, with no connectivity '
      'between them; on reconnect both settle on the fold\'s rule',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
        final f = fleet;

        await f.linkDevice(master: f.a, target: f.b);
        await f.introduce(f.a, f.c);

        const original = 'case-20 the row both devices will change';
        const edited = 'case-20 EDITED on A';
        await f.a.messaging.sendText(f.c.identityNodeId, original);
        await waitUntil(
          () async =>
              (await f.b.conversation(f.c.identityNodeId)).contains(original),
          what: 'B to mirror the row before the split',
          describe: () async => 'B conv=${await f.b.conversation(f.c.identityNodeId)}',
          timeout: const Duration(minutes: 5),
        );

        final idOnA = await idOf(f.a, f.c.identityNodeId, original);
        final idOnB = await idOf(f.b, f.c.identityNodeId, original);
        expect(
          idOnB,
          idOnA,
          reason: 'the two devices must be talking about the SAME row — a '
              'mirror that re-keys the id turns this case into two unrelated '
              'edits and would pass for the wrong reason',
        );

        // NO CONNECTIVITY BETWEEN THEM, done the way a single-host stand does
        // it: each device acts while the other is not running. Neither sees the
        // other's change until both are up again.
        await f.b.stop();
        await f.a.messaging.editOwnMessage(idOnA, edited);
        await f.a.stop();
        await f.b.start();
        await f.b.messaging.deleteMessageLocally(idOnB);
        await f.a.start();

        // Let the reconnection do whatever it is going to do. There is nothing
        // to poll for a NON-event, so this waits for the pair to stop changing
        // rather than for a particular outcome.
        var lastA = <String>[];
        var lastB = <String>[];
        var stable = 0;
        await waitUntil(
          () async {
            final nowA = await f.a.conversation(f.c.identityNodeId);
            final nowB = await f.b.conversation(f.c.identityNodeId);
            final unchanged = '$nowA' == '$lastA' && '$nowB' == '$lastB';
            lastA = nowA;
            lastB = nowB;
            stable = unchanged ? stable + 1 : 0;
            return stable >= 8;
          },
          what: 'A and B to stop changing after the split heals',
          describe: () async => 'A=$lastA B=$lastB (stable for $stable polls)',
          interval: const Duration(seconds: 2),
          timeout: const Duration(minutes: 6),
        );

        final onA = await f.a.snapshot(conversationPeer: f.c.identityNodeId);
        final onB = await f.b.snapshot(conversationPeer: f.c.identityNodeId);
        E2eLog.line('case 20 settled: A=$lastA B=$lastB');

        // WHAT MUST HOLD REGARDLESS OF THE RULE: the signed device-group log is
        // the shared object, and a split-brain must not fork it, duplicate a
        // row or leave a hole in a writer's chain.
        await expectConverged(
          f.a,
          f.b,
          what: 'a concurrent edit and delete must not fork the device group',
        );

        // WHAT THE RULE CURRENTLY IS, recorded rather than argued.
        //
        // Read out of the code before it was asserted here
        // (doc/MESSAGE-EDIT-DELETE-DESIGN.md and
        // lib/state/messaging_device_mirror.dart):
        //
        //   * DELETE IS PERMANENT AND LOCAL. `deleteMessageLocally` writes a
        //     tombstone, and `applyMessage` refuses any mirror carrying an id
        //     that is tombstoned here — the resurrection invariant. So the
        //     deleting device never gets the row back, by design;
        //   * AN EDIT DOES NOT MIRROR. The mirror emits on `onMessageStored`
        //     and `applyMessage` drops an id it already holds, so a body
        //     rewritten on one device is not carried to a sibling that already
        //     has the row.
        //
        // Both halves point the same way, so the settled state is deterministic:
        // A keeps the edited row, B keeps nothing. That is what is pinned. It
        // is NOT an endorsement — a user with two devices sees two different
        // conversations — but it is the fold's actual behaviour today, and a
        // change to it should change this assertion deliberately.
        // Asserted about THE ROW, not about the whole conversation: the
        // consent handshake leaves its greeting in there too, and a whole-list
        // expectation turns "the greeting exists" into a case-20 failure.
        expect(
          lastA,
          contains(edited),
          reason: 'A edited its own row and nothing arrived to undo that: $onA',
        );
        expect(
          lastA,
          isNot(contains(original)),
          reason: 'the edit replaced the body in place: $onA',
        );
        expect(
          lastB,
          isNot(contains(original)),
          reason: 'B tombstoned the row; the tombstone is permanent: $onB',
        );
        expect(
          lastB,
          isNot(contains(edited)),
          reason: 'the edit cannot resurrect a row B has tombstoned — that is '
              'the resurrection invariant, and it is the half of this rule '
              'that is deliberate: $onB',
        );
        expect(
          convergenceOf(onA, onB, requireConversationAgreement: true).agree,
          isFalse,
          reason: 'PINNED DIVERGENCE, not a passing property: with delete '
              'local-and-permanent and edit not mirrored, the two devices of '
              'one identity end with different conversations. When the mirror '
              'learns to carry edits and deletes, this expectation is the one '
              'to flip — and case 20 becomes a convergence assertion like the '
              'other two.\n  A: $onA\n  B: $onB',
        );
      },
      skip: gate.skip,
    );
  });
}
