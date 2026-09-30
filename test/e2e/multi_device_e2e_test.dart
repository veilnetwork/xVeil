@Timeout(Duration(minutes: 40))
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';

import 'convergence_oracle.dart';
import 'device_fixture.dart';
import 'e2e_env.dart';

/// Selected cases of the multi-device checklist, run end to end against
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
      fail(
        '${device.label} holds ${match.length} rows with body "$body"; its '
        'conversation with ${peer.short} is '
        '${rows.map((m) => "${m.direction.name}:${m.body}").toList()}',
      );
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
    await waitUntil(
      () async => convergenceOf(
        await x.snapshot(conversationPeer: conversationPeer),
        await y.snapshot(conversationPeer: conversationPeer),
        requireConversationAgreement: requireConversationAgreement,
      ).agree,
      what: what,
      describe: () async {
        final a = await x.snapshot(conversationPeer: conversationPeer);
        final b = await y.snapshot(conversationPeer: conversationPeer);
        return convergenceOf(
          a,
          b,
          requireConversationAgreement: requireConversationAgreement,
        ).describe();
      },
      timeout: const Duration(minutes: 3),
    );
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
      reason:
          '$what\n${verdict.describe()}\n  ${x.label}: $a\n  ${y.label}: $b',
    );
  }

  group('multi-device checklist', () {
    // ---------------------------------------------------------------------
    test('case 3/8 — C writes to identity X while A and B are both up: the '
        'message lands on each of them exactly once', () async {
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
        describe: () async =>
            'A conv=${await f.a.conversation(f.c.identityNodeId)}',
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
    }, skip: gate.skip);

    // ---------------------------------------------------------------------
    test('case 3 — A writes to C while B is online: B mirrors the outgoing row '
        'exactly once', () async {
      E2eFleet? fleet;
      addTearDown(() async => fleet?.dispose());
      fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
      final f = fleet;

      await f.linkDevice(master: f.a, target: f.b);
      await f.introduce(f.a, f.c);

      const body = 'case-3 from A to C with B online';
      await f.a.messaging.sendText(f.c.identityNodeId, body);
      await waitUntil(
        () async => (await f.c.conversation(f.a.identityNodeId)).contains(body),
        what: 'C to receive A\'s message',
        describe: () async => 'C=${await f.c.conversation(f.a.identityNodeId)}',
        timeout: const Duration(minutes: 3),
      );
      await waitUntil(
        () async => (await f.b.conversation(f.c.identityNodeId)).contains(body),
        what: 'online B to mirror A\'s outgoing message',
        describe: () async => 'B=${await f.b.conversation(f.c.identityNodeId)}',
        timeout: const Duration(minutes: 5),
      );

      final id = await idOf(f.a, f.c.identityNodeId, body);
      final mirrored = (await f.b.conversationRows(
        f.c.identityNodeId,
      )).singleWhere((m) => m.id == id);
      expect(mirrored.direction, MessageDirection.outgoing);
      final onA = await f.a.snapshot(conversationPeer: f.c.identityNodeId);
      final onB = await f.b.snapshot(conversationPeer: f.c.identityNodeId);
      expect(exactlyOnce(onA, id), isNull, reason: 'A: $onA');
      expect(exactlyOnce(onB, id), isNull, reason: 'B: $onB');
      await expectConverged(
        f.a,
        f.b,
        conversationPeer: f.c.identityNodeId,
        requireConversationAgreement: true,
        what: 'A and online B must hold the same outgoing conversation',
      );
    }, skip: gate.skip);

    // ---------------------------------------------------------------------
    test(
      'case 44 — A/B and C/D both linked; A to C reaches all four once',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(
          gate: gate,
          labels: const ['A', 'B', 'C', 'D'],
        );
        final f = fleet;
        await f.linkDevice(master: f.a, target: f.b);
        await f.linkDevice(master: f.c, target: f.d);
        await f.introduce(f.a, f.c);

        const body = 'case-44 one logical message across four devices';
        await f.a.messaging.sendText(f.c.identityNodeId, body);
        await waitUntil(
          () async =>
              (await f.a.conversation(f.c.identityNodeId)).contains(body) &&
              (await f.b.conversation(f.c.identityNodeId)).contains(body) &&
              (await f.c.conversation(f.a.identityNodeId)).contains(body) &&
              (await f.d.conversation(f.a.identityNodeId)).contains(body),
          what: 'all four devices to hold the A-to-C message',
          describe: () async =>
              'A=${await f.a.conversation(f.c.identityNodeId)} '
              'B=${await f.b.conversation(f.c.identityNodeId)} '
              'C=${await f.c.conversation(f.a.identityNodeId)} '
              'D=${await f.d.conversation(f.a.identityNodeId)}',
          timeout: const Duration(minutes: 5),
        );
        final id = await idOf(f.a, f.c.identityNodeId, body);
        for (final device in [f.a, f.b]) {
          expect(
            exactlyOnce(
              await device.snapshot(conversationPeer: f.c.identityNodeId),
              id,
            ),
            isNull,
          );
        }
        for (final device in [f.c, f.d]) {
          expect(
            exactlyOnce(
              await device.snapshot(conversationPeer: f.a.identityNodeId),
              id,
            ),
            isNull,
          );
        }
        await expectConverged(
          f.a,
          f.b,
          conversationPeer: f.c.identityNodeId,
          requireConversationAgreement: true,
          what: 'X devices to converge in the four-way test',
        );
        await expectConverged(
          f.c,
          f.d,
          conversationPeer: f.a.identityNodeId,
          requireConversationAgreement: true,
          what: 'Y devices to converge in the four-way test',
        );
      },
      skip: gate.skip,
    );

    // ---------------------------------------------------------------------
    test('case 5 — a late-linked B receives its earlier A/C history', () async {
      E2eFleet? fleet;
      addTearDown(() async => fleet?.dispose());
      fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
      final f = fleet;

      await f.introduce(f.a, f.c);
      const beforeLink = 'case-5 history before B joins';
      await f.a.messaging.sendText(f.c.identityNodeId, beforeLink);
      await waitUntil(
        () async =>
            (await f.c.conversation(f.a.identityNodeId)).contains(beforeLink),
        what: 'C to receive the pre-link message',
        describe: () async => 'C=${await f.c.conversation(f.a.identityNodeId)}',
        timeout: const Duration(minutes: 3),
      );

      await f.linkDevice(master: f.a, target: f.b);
      await waitUntil(
        () async => (await f.b.groups!.addressableOwnDevices()).contains(
          f.a.deviceNodeId,
        ),
        what: 'B to learn the master device address after link',
        describe: () async {
          final aSync = await f.a.groups!.deviceSyncState();
          final bSync = await f.b.groups!.deviceSyncState();
          return 'B destinations=${await f.b.groups!.addressableOwnDevices()} '
              'A owns=${await f.a.groups!.ownsDeviceGroup()} '
              'A events=${aSync.keys.toList()} '
              'B events=${bSync.keys.toList()}';
        },
        timeout: const Duration(seconds: 90),
      );
      // The source schedules an automatic history replay after link. Its
      // durable watermark distinguishes an unanswered replay from a slow
      // delivery to B.
      await waitUntil(
        () async =>
            (await f.a.storage.getSetting(
              'device.history.served.v1:${f.b.deviceNodeId.hex}',
            )) !=
            null,
        what: 'A to start the automatic history replay for B',
        describe: () async =>
            'A served marker=${await f.a.storage.getSetting('device.history.served.v1:${f.b.deviceNodeId.hex}')}; '
            'A sync=${await f.a.groups!.deviceSyncState()}',
        timeout: const Duration(minutes: 3),
      );
      await waitUntil(
        () async =>
            (await f.b.conversation(f.c.identityNodeId)).contains(beforeLink),
        what: 'B to receive the automatic pre-link history',
        describe: () async =>
            'B=${await f.b.conversation(f.c.identityNodeId)}; '
            'A=${await f.a.conversation(f.c.identityNodeId)}',
        timeout: const Duration(minutes: 5),
      );
      final id = await idOf(f.a, f.c.identityNodeId, beforeLink);
      final onB = await f.b.snapshot(conversationPeer: f.c.identityNodeId);
      expect(exactlyOnce(onB, id), isNull, reason: 'B: $onB');
    }, skip: gate.skip);

    // ---------------------------------------------------------------------
    test(
      'cases 1/6 — C rings A and B; A answers; A calls C while B stays online',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
        final f = fleet;

        await f.linkDevice(master: f.a, target: f.b);
        await f.introduce(f.c, f.a);
        await waitUntil(
          () async =>
              (await f.b.storage.getContact(f.c.identityNodeId))?.status ==
              ContactStatus.accepted,
          what: 'B to learn the accepted C contact before call setup',
          describe: () async =>
              'B contact=${(await f.b.storage.getContact(f.c.identityNodeId))?.status}',
          timeout: const Duration(minutes: 3),
        );
        final aCalls = f.a.calls;
        final bCalls = f.b.calls;
        final cCalls = f.c.calls;

        await cCalls.placeCall(
          f.a.identityNodeId,
          const CallMedia(audio: true),
        );
        await waitUntil(
          () async =>
              aCalls.current?.status == CallStatus.ringing &&
              bCalls.current?.status == CallStatus.ringing,
          what: 'A and B to ring for the same C call',
          describe: () async =>
              'A=${aCalls.current?.status} B=${bCalls.current?.status} '
              'C=${cCalls.current?.status}',
          timeout: const Duration(minutes: 3),
        );
        expect(aCalls.current!.callId, bCalls.current!.callId);
        await aCalls.accept();
        await waitUntil(
          () async =>
              bCalls.current?.status != CallStatus.ringing &&
              (cCalls.current?.status == CallStatus.connecting ||
                  cCalls.current?.status == CallStatus.active),
          what: 'B to stop ringing when A answers and C to connect',
          describe: () async =>
              'A=${aCalls.current?.status} B=${bCalls.current?.status} '
              'C=${cCalls.current?.status}',
          timeout: const Duration(minutes: 3),
        );
        await waitUntil(
          () async =>
              ((aCalls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0 &&
              ((cCalls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0,
          what: 'A and C to receive call media while B stays online',
          describe: () async =>
              'A=${aCalls.mediaDiagnostics['rx_pkts']} '
              'C=${cCalls.mediaDiagnostics['rx_pkts']}',
          timeout: const Duration(seconds: 20),
        );
        await cCalls.hangup();
        await waitUntil(
          () async =>
              aCalls.current?.status == CallStatus.ended ||
              aCalls.current == null,
          what: 'A to see C hang up',
          describe: () async => 'A=${aCalls.current?.status}',
          timeout: const Duration(minutes: 2),
        );

        await aCalls.placeCall(
          f.c.identityNodeId,
          const CallMedia(audio: true),
        );
        await waitUntil(
          () async => cCalls.current?.status == CallStatus.ringing,
          what: 'C to ring for A without B intercepting the call',
          describe: () async =>
              'A=${aCalls.current?.status} B=${bCalls.current?.status} '
              'C=${cCalls.current?.status}',
          timeout: const Duration(minutes: 3),
        );
        expect(bCalls.current?.isLive ?? false, isFalse);
        await cCalls.accept();
        await waitUntil(
          () async =>
              aCalls.current?.status == CallStatus.connecting ||
              aCalls.current?.status == CallStatus.active,
          what: 'A to connect to C while B stays online',
          describe: () async =>
              'A=${aCalls.current?.status} B=${bCalls.current?.status} '
              'C=${cCalls.current?.status}',
          timeout: const Duration(minutes: 3),
        );
        expect(bCalls.current?.isLive ?? false, isFalse);
        await waitUntil(
          () async =>
              ((aCalls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0 &&
              ((cCalls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0,
          what: 'A and C to receive outgoing-call media with B online',
          describe: () async =>
              'A=${aCalls.mediaDiagnostics['rx_pkts']} '
              'C=${cCalls.mediaDiagnostics['rx_pkts']}',
          timeout: const Duration(seconds: 20),
        );
        await aCalls.hangup();
        await waitUntil(
          () async =>
              cCalls.current?.status == CallStatus.ended ||
              cCalls.current == null,
          what: 'C to see A hang up',
          describe: () async => 'C=${cCalls.current?.status}',
          timeout: const Duration(minutes: 2),
        );
      },
      skip: gate.skip,
    );

    // ---------------------------------------------------------------------
    test(
      'case 37 — C calls X; B answers without a B-C session',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
        final f = fleet;
        await f.linkDevice(master: f.a, target: f.b);
        await f.introduce(f.c, f.a);
        await waitUntil(
          () async =>
              (await f.b.storage.getContact(f.c.identityNodeId))?.status ==
              ContactStatus.accepted,
          what: 'B to know C before accepting its call',
          timeout: const Duration(minutes: 3),
        );

        final aCalls = f.a.calls;
        final bCalls = f.b.calls;
        final cCalls = f.c.calls;
        await cCalls.placeCall(
          f.a.identityNodeId,
          const CallMedia(audio: true),
        );
        await waitUntil(
          () async =>
              aCalls.current?.status == CallStatus.ringing &&
              bCalls.current?.status == CallStatus.ringing,
          what: 'A and B to ring for C',
          timeout: const Duration(minutes: 3),
        );
        expect(aCalls.current!.callId, bCalls.current!.callId);
        expect(
          (await f.b.stack.transport.peers()).any(
            (peer) => peer.nodeId == f.c.deviceNodeId && peer.isActive,
          ),
          isFalse,
          reason: 'the answer must work before B has a direct session to C',
        );
        await bCalls.accept();
        await waitUntil(
          () async =>
              aCalls.current?.status != CallStatus.ringing &&
              (cCalls.current?.status == CallStatus.connecting ||
                  cCalls.current?.status == CallStatus.active),
          what: 'A to stop ringing and C to connect to answering device B',
          describe: () async =>
              'A=${aCalls.current?.status} B=${bCalls.current?.status} '
              'C=${cCalls.current?.status}',
          timeout: const Duration(seconds: 100),
        );
        await waitUntil(
          () async =>
              ((bCalls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0 &&
              ((cCalls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0,
          what: 'B and C to receive call media in both directions',
          describe: () async =>
              'B=${bCalls.mediaDiagnostics} C=${cCalls.mediaDiagnostics}',
          timeout: const Duration(seconds: 20),
        );
        E2eLog.line(
          'call media delivered: B rx=${bCalls.mediaDiagnostics['rx_pkts']} '
          'C rx=${cCalls.mediaDiagnostics['rx_pkts']}',
        );
        await bCalls.hangup();
        await waitUntil(
          () async =>
              cCalls.current?.status == CallStatus.ended ||
              cCalls.current == null,
          what: 'C to see B hang up',
          timeout: const Duration(minutes: 2),
        );
      },
      skip: gate.skip,
    );

    // ---------------------------------------------------------------------
    test('case 7 — A sends a file to C and online B gets the bytes', () async {
      E2eFleet? fleet;
      addTearDown(() async => fleet?.dispose());
      fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
      final f = fleet;

      await f.linkDevice(master: f.a, target: f.b);
      await f.introduce(f.a, f.c);
      final bytes = Uint8List.fromList(
        List<int>.generate(150 * 1024, (i) => (i * 31 + 7) & 255),
      );
      const name = 'case-7-document.bin';
      await f.a.messaging.sendFile(f.c.identityNodeId, bytes, name);
      await waitUntil(
        () async => (await f.c.conversationRows(
          f.a.identityNodeId,
        )).any((m) => m.fileName == name),
        what: 'C to receive the file message',
        describe: () async => 'C=${await f.c.conversation(f.a.identityNodeId)}',
        timeout: const Duration(minutes: 5),
      );
      await waitUntil(
        () async => (await f.b.conversationRows(
          f.c.identityNodeId,
        )).any((m) => m.fileName == name),
        what: 'B to mirror the file message',
        describe: () async => 'B=${await f.b.conversation(f.c.identityNodeId)}',
        timeout: const Duration(minutes: 5),
      );
      final onA = (await f.a.conversationRows(
        f.c.identityNodeId,
      )).singleWhere((m) => m.fileName == name);
      final onB = (await f.b.conversationRows(
        f.c.identityNodeId,
      )).singleWhere((m) => m.fileName == name);
      expect(onB.id, onA.id);
      expect(onB.direction, MessageDirection.outgoing);
      final cid = onB.fileContentId;
      expect(cid, isNotNull, reason: 'large files must mirror a content ref');
      E2eLog.line(
        'B mirrored file size=${onB.fileSize} name=${onB.fileName} '
        'auto=${f.b.messaging.fileDownloadPolicy.allowsAuto(onB.fileSize, onB.fileName)} '
        'pullAttached=${f.b.messaging.deviceContentPull != null}',
      );
      expect(onB.fileSize, bytes.length);
      await waitUntil(
        () => f.b.storage.hasFile(cid!),
        what: 'online B to retrieve the actual file bytes automatically',
        describe: () async {
          final gidHex = await f.b.groups!.deviceGroupIdHex();
          final refs = gidHex == null
              ? <String>{}
              : await f.b.groups!.referencedContentIds(NodeId.fromHex(gidHex));
          return 'B content ID=$cid group=$gidHex refs=${refs.contains(cid)} '
              'holders=${await f.b.groups!.addressableOwnDevices()} '
              'size=${onB.fileSize} auto=${f.b.messaging.fileDownloadPolicy.allowsAuto(onB.fileSize, onB.fileName)} '
              'pullAttached=${f.b.messaging.deviceContentPull != null} '
              'A has=${await f.a.storage.hasFile(cid!)} '
              'C has=${await f.c.storage.hasFile(cid)}';
        },
        timeout: const Duration(seconds: 90),
      );
      expect(await f.b.storage.loadFile(cid!), bytes);
      final onBSnapshot = await f.b.snapshot(
        conversationPeer: f.c.identityNodeId,
      );
      expect(exactlyOnce(onBSnapshot, onA.id), isNull);
    }, skip: gate.skip);

    // ---------------------------------------------------------------------
    test(
      'case 7 offline B — file bytes arrive after B reconnects with C down',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
        final f = fleet;

        await f.linkDevice(master: f.a, target: f.b);
        await f.introduce(f.a, f.c);
        await waitUntil(
          () async =>
              (await f.b.storage.getContact(f.c.identityNodeId))?.status ==
              ContactStatus.accepted,
          what: 'B to know C before going offline',
          timeout: const Duration(minutes: 3),
        );
        await f.b.stop();
        final bytes = Uint8List.fromList(
          List<int>.generate(150 * 1024, (i) => (i * 17 + 11) & 255),
        );
        const name = 'case-7-offline.bin';
        await f.a.messaging.sendFile(f.c.identityNodeId, bytes, name);
        await waitUntil(
          () async => (await f.c.conversationRows(
            f.a.identityNodeId,
          )).any((m) => m.fileName == name),
          what: 'C to receive the file offer before going offline',
          timeout: const Duration(minutes: 3),
        );
        await f.c.stop();
        await f.b.start();
        await waitUntil(
          () async => (await f.b.conversationRows(
            f.c.identityNodeId,
          )).any((m) => m.fileName == name),
          what: 'B to mirror A\'s file row with C offline',
          timeout: const Duration(minutes: 5),
        );
        final onA = (await f.a.conversationRows(
          f.c.identityNodeId,
        )).singleWhere((m) => m.fileName == name);
        final onB = (await f.b.conversationRows(
          f.c.identityNodeId,
        )).singleWhere((m) => m.fileName == name);
        expect(onB.id, onA.id);
        expect(onB.direction, MessageDirection.outgoing);
        expect(onB.fileSize, bytes.length);
        final cid = onB.fileContentId;
        expect(cid, isNotNull);
        await waitUntil(
          () => f.b.storage.hasFile(cid!),
          what: 'B to download the file from online A after reconnect',
          timeout: const Duration(minutes: 3),
        );
        expect(await f.b.storage.loadFile(cid!), bytes);
        expect(
          exactlyOnce(
            await f.b.snapshot(conversationPeer: f.c.identityNodeId),
            onA.id,
          ),
          isNull,
        );
      },
      skip: gate.skip,
    );

    // ---------------------------------------------------------------------
    test(
      'cases 4/9 — B catches up after missing both directions offline',
      () async {
        E2eFleet? fleet;
        addTearDown(() async => fleet?.dispose());
        fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
        final f = fleet;

        await f.linkDevice(master: f.a, target: f.b);
        await f.introduce(f.a, f.c);
        await waitUntil(
          () async =>
              (await f.b.storage.getContact(f.c.identityNodeId))?.status ==
              ContactStatus.accepted,
          what: 'B to know C before its offline interval',
          describe: () async =>
              'B contact=${(await f.b.storage.getContact(f.c.identityNodeId))?.status}',
          timeout: const Duration(minutes: 3),
        );
        await f.b.stop();
        const outgoing = 'case-4 outgoing while B offline';
        const incoming = 'case-9 incoming while B offline';
        await f.a.messaging.sendText(f.c.identityNodeId, outgoing);
        await f.c.messaging.sendText(f.a.identityNodeId, incoming);
        await waitUntil(
          () async =>
              (await f.c.conversation(f.a.identityNodeId)).contains(outgoing) &&
              (await f.a.conversation(f.c.identityNodeId)).contains(incoming),
          what: 'A and C to finish their live exchange while B is down',
          describe: () async =>
              'A=${await f.a.conversation(f.c.identityNodeId)} '
              'C=${await f.c.conversation(f.a.identityNodeId)}',
          timeout: const Duration(minutes: 3),
        );
        await f.c.stop();
        await f.b.start();
        await waitUntil(
          () async {
            final rows = await f.b.conversation(f.c.identityNodeId);
            return rows.contains(outgoing) && rows.contains(incoming);
          },
          what: 'B to catch up both directions with C offline and A online',
          describe: () async =>
              'B=${await f.b.conversation(f.c.identityNodeId)}',
          timeout: const Duration(minutes: 5),
        );
        final rows = await f.b.conversationRows(f.c.identityNodeId);
        expect(
          rows.singleWhere((m) => m.body == outgoing).direction,
          MessageDirection.outgoing,
        );
        expect(
          rows.singleWhere((m) => m.body == incoming).direction,
          MessageDirection.incoming,
        );
        await expectConverged(
          f.a,
          f.b,
          conversationPeer: f.c.identityNodeId,
          requireConversationAgreement: true,
          what: 'B must converge with A after reconnect',
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
          () async =>
              (await f.c.conversation(f.a.identityNodeId)).contains(body),
          what: 'C to receive A\'s message',
          describe: () async =>
              'C conv=${await f.c.conversation(f.a.identityNodeId)}',
          timeout: const Duration(minutes: 3),
        );
        final id = await idOf(f.a, f.c.identityNodeId, body);
        await waitUntil(
          () async => (await f.a.groups!.deviceSyncState()).containsKey((
            DeviceSyncKind.msgMirror,
            id,
          )),
          what: 'A to commit the outgoing mirror before going offline',
          describe: () async => 'A group=${await f.a.snapshot()}',
          timeout: const Duration(minutes: 2),
        );

        // Current policy skips mailbox deposits to sibling device addresses.
        // Take A and C down after C has the row to measure whether any other
        // store can still supply B on reconnect.
        await f.a.stop();
        await f.c.stop();
        await f.b.start();

        // Now B is the only device of identity X that is running. The row can
        // only reach it from the mailbox: A is gone, and there is no live leg
        // to anybody. This is the case that fails when the mirror is deposited
        // for nobody, or when the drain never wakes.
        await waitUntil(
          () async =>
              (await f.b.conversation(f.c.identityNodeId)).contains(body),
          what:
              'B to drain its identity\'s own outgoing message from the '
              'mailbox with every other device down',
          describe: () async =>
              'B conv=${await f.b.conversation(f.c.identityNodeId)}; '
              'B state=${await f.b.snapshot()}',
          timeout: const Duration(minutes: 3),
        );

        final rows = await f.b.conversationRows(f.c.identityNodeId);
        final mirrored = rows.singleWhere((m) => m.body == body);
        expect(
          mirrored.direction,
          MessageDirection.outgoing,
          reason:
              'the row is the IDENTITY\'s own outgoing message, so it must '
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
      'case 20 — B deletion wins over A edit after both reconnect',
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
          describe: () async =>
              'B conv=${await f.b.conversation(f.c.identityNodeId)}',
          timeout: const Duration(minutes: 5),
        );

        final idOnA = await idOf(f.a, f.c.identityNodeId, original);
        final idOnB = await idOf(f.b, f.c.identityNodeId, original);
        expect(
          idOnB,
          idOnA,
          reason:
              'the two devices must be talking about the SAME row — a '
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
        await waitUntil(
          () async => (await f.b.groups!.deviceSyncState()).containsKey((
            DeviceSyncKind.msgGone,
            idOnB,
          )),
          what: 'B to commit the delete to the device journal',
          timeout: const Duration(minutes: 2),
        );
        await f.a.start();

        await waitUntil(
          () async {
            final a = await f.a.conversationRows(f.c.identityNodeId);
            final b = await f.b.conversationRows(f.c.identityNodeId);
            return a.every((m) => m.id != idOnA) &&
                b.every((m) => m.id != idOnB);
          },
          what: 'the sibling delete to remove the row on A as well as B',
          describe: () async =>
              'A=${await f.a.conversation(f.c.identityNodeId)} '
              'B=${await f.b.conversation(f.c.identityNodeId)}',
          timeout: const Duration(minutes: 4),
        );

        final onA = await f.a.snapshot(conversationPeer: f.c.identityNodeId);
        final onB = await f.b.snapshot(conversationPeer: f.c.identityNodeId);
        await expectConverged(
          f.a,
          f.b,
          conversationPeer: f.c.identityNodeId,
          requireConversationAgreement: true,
          what: 'A and B to converge after the edit/delete split',
        );
        expect(onA.conversationMessageIds, isNot(contains(idOnA)));
        expect(onB.conversationMessageIds, isNot(contains(idOnB)));
      },
      skip: gate.skip,
    );
  });
}
