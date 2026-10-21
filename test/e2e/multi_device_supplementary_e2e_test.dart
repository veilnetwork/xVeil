@Timeout(Duration(minutes: 15))
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/log.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

void main() {
  final gate = E2eGate.read();

  Future<void> holds(E2eDevice device, NodeId peer, String body) => waitUntil(
    () async =>
        (await device.conversationRows(
          peer,
        )).where((row) => row.body == body).length ==
        1,
    what: '${device.label} holds exactly one $body',
    timeout: const Duration(minutes: 3),
    describe: () async => '${await device.conversation(peer)}',
  );

  Future<void> mediaBoth(E2eDevice a, E2eDevice b) => waitUntil(
    () =>
        ((a.calls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0 &&
        ((b.calls.mediaDiagnostics['rx_pkts'] as num?) ?? 0) > 0,
    what: '${a.label}/${b.label} receive bidirectional native media',
    describe: () =>
        '${a.label}: ${a.calls.current?.status} '
        'rx=${a.calls.mediaDiagnostics['rx_pkts']} '
        '${b.label}: ${b.calls.current?.status} '
        'rx=${b.calls.mediaDiagnostics['rx_pkts']}',
    timeout: const Duration(seconds: 30),
  );

  test(
    'authenticated anonymous offers still connect after sender-proof gate',
    () async {
      final f = await E2eFleet.start(
        gate: gate,
        labels: const ['A', 'C'],
        anonymous: true,
      );
      addTearDown(f.dispose);
      await f.introduce(f.a, f.c);
      await f.c.calls.placeCall(
        f.a.identityNodeId,
        const CallMedia(audio: true),
      );
      await waitUntil(
        () => f.a.calls.current?.status == CallStatus.ringing,
        what: 'authenticated onion cold offer rings A',
      );
      await f.a.calls.accept();
      await mediaBoth(f.a, f.c);
      await f.c.calls.hangup();
      await waitUntil(
        () => !(f.a.calls.current?.isLive ?? false),
        what: 'authenticated onion call ends',
      );
    },
    skip: gate.mediaSkip,
  );

  Future<E2eFleet> twoIdentities() async {
    final f = await E2eFleet.start(gate: gate);
    addTearDown(f.dispose);
    await f.linkDevice(master: f.a, target: f.b);
    await f.linkDevice(master: f.c, target: f.d);
    await f.introduce(f.a, f.c);
    await waitUntil(
      () async =>
          (await f.b.storage.getContact(f.c.identityNodeId))?.status ==
              ContactStatus.accepted &&
          (await f.d.storage.getContact(f.a.identityNodeId))?.status ==
              ContactStatus.accepted,
      what: 'both siblings learn accepted opposite identity',
    );
    return f;
  }

  test('case 45 — A/D online, B/C offline, then all reconnect', () async {
    final f = await twoIdentities();
    final x = f.a.identityNodeId;
    final y = f.c.identityNodeId;
    await f.b.stop();
    await f.c.stop();
    expect(await f.a.messaging.sendText(y, 'mixed-online-A-to-Y'), isTrue);
    await holds(f.d, x, 'mixed-online-A-to-Y');
    expect(await f.d.messaging.sendText(x, 'mixed-online-D-to-X'), isTrue);
    await holds(f.a, y, 'mixed-online-D-to-X');
    await f.b.start();
    await f.c.start();
    for (final device in [f.a, f.b]) {
      for (final body in ['mixed-online-A-to-Y', 'mixed-online-D-to-X']) {
        await holds(device, y, body);
      }
    }
    for (final device in [f.c, f.d]) {
      for (final body in ['mixed-online-A-to-Y', 'mixed-online-D-to-X']) {
        await holds(device, x, body);
      }
    }
  }, skip: gate.skip);

  test('case 46 — A calls Y, D answers while B/C remain online', () async {
    final f = await twoIdentities();
    await f.a.calls.placeCall(f.c.identityNodeId, const CallMedia(audio: true));
    await waitUntil(
      () =>
          f.c.calls.current?.status == CallStatus.ringing &&
          f.d.calls.current?.status == CallStatus.ringing,
      what: 'both devices of Y ring',
    );
    expect(f.c.calls.current!.callId, f.d.calls.current!.callId);
    expect(f.b.calls.current?.isLive ?? false, isFalse);
    await f.d.calls.accept();
    try {
      await mediaBoth(f.a, f.d);
    } catch (_) {
      final callId = f.d.calls.current?.callId;
      for (final line in devLogSnapshot(limit: 4000).lines.where((line) =>
          line.contains('call-sig') || (callId != null && line.contains(callId)))) {
        E2eLog.line(line);
      }
      rethrow;
    }
    await waitUntil(
      () => !(f.c.calls.current?.isLive ?? false),
      what: 'C yields media to answering sibling D',
    );
    expect(f.b.calls.current?.isLive ?? false, isFalse);
    await f.a.calls.hangup();
    await waitUntil(
      () => !f.devices.values.any((d) => d.calls.current?.isLive ?? false),
      what: 'all four devices finish call',
    );
  }, skip: gate.mediaSkip);

  test(
    'case 36 — evicting B local attachment leaves A/C copies intact',
    () async {
      final f = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
      addTearDown(f.dispose);
      await f.linkDevice(master: f.a, target: f.b);
      await f.introduce(f.a, f.c);
      final peer = f.c.identityNodeId;
      final data = Uint8List.fromList(
        List.generate(150 * 1024, (i) => i & 255),
      );
      await f.a.messaging.sendFile(peer, data, 'evict-local-cache.bin');
      await waitUntil(
        () async => (await f.b.conversationRows(
          peer,
        )).any((m) => m.fileName == 'evict-local-cache.bin'),
        what: 'B mirrors attachment metadata',
      );
      final row = (await f.b.conversationRows(
        peer,
      )).singleWhere((m) => m.fileName == 'evict-local-cache.bin');
      final cid = row.fileContentId!;
      await waitUntil(
        () async =>
            await f.b.storage.hasFile(cid) && await f.c.storage.hasFile(cid),
        what: 'all three holders have verified bytes before B cache eviction',
      );
      await f.b.storage.deleteStoredFile(cid);
      expect(await f.b.storage.hasFile(cid), isFalse);
      expect(await f.a.storage.loadFile(cid), data);
      expect(await f.c.storage.loadFile(cid), data);
      expect(
        (await f.b.conversationRows(peer)).where((m) => m.id == row.id),
        hasLength(1),
      );
      await f.b.messaging.downloadContent(f.c.deviceNodeId, cid);
      await waitUntil(
        () => f.b.storage.hasFile(cid),
        what: 'B can download an evicted attachment again',
      );
      expect(await f.b.storage.loadFile(cid), data);
    },
    skip: gate.skip,
  );

  test(
    'case 42 — A disappears during a call while B stays online',
    () async {
      final f = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
      addTearDown(f.dispose);
      await f.linkDevice(master: f.a, target: f.b);
      await f.introduce(f.a, f.c);
      await f.a.inZone(
        () => f.a.calls.placeCall(
          f.c.identityNodeId,
          const CallMedia(audio: true),
        ),
      );
      await waitUntil(
        () => f.c.calls.current?.status == CallStatus.ringing,
        what: 'C rings for A',
      );
      await f.c.inZone(() => f.c.calls.accept());
      await mediaBoth(f.a, f.c);
      await f.a.stop();
      await waitUntil(
        () =>
            !(f.c.calls.current?.isLive ?? false) &&
            !(f.b.calls.current?.isLive ?? false),
        what: 'C times out missing A and online B has no orphan call',
        timeout: const Duration(seconds: 100),
        describe: () =>
            'B=${f.b.calls.current?.status} C=${f.c.calls.current?.status}',
      );
    },
    skip: gate.mediaSkip,
  );

  test(
    'cases 54/55 — offline B cannot read group traffic after X removal',
    () async {
      final f = await twoIdentities();
      final gid = await f.c.groups!.createGroup('Removal while B offline');
      expect(
        await f.c.groups!.addControlOp(
          gid,
          ControlOp.addMember,
          target: f.a.identityNodeId,
          role: GroupRole.member,
        ),
        isTrue,
      );
      await waitUntil(
        () async => await f.b.groups!.load(gid) != null,
        what: 'B learns membership before going offline',
      );
      expect(await f.c.groups!.postMessage(gid, 'before-X-removal'), isTrue);
      await waitUntil(
        () async => (await f.b.groups!.messagesOf(
          gid,
        )).any((m) => m.body == 'before-X-removal'),
        what: 'B decrypts positive control before removal',
      );
      final oldEpoch = (await f.c.groups!.stateOf(gid))!.epochDescriptor!;
      await f.b.stop();
      expect(
        await f.c.groups!.addControlOp(
          gid,
          ControlOp.removeMember,
          target: f.a.identityNodeId,
        ),
        isTrue,
      );
      final newEpoch = (await f.c.groups!.stateOf(gid))!.epochDescriptor!;
      expect(newEpoch.epoch, greaterThan(oldEpoch.epoch));
      expect(newEpoch.keyCommitment, isNot(oldEpoch.keyCommitment));
      expect(await f.c.groups!.postMessage(gid, 'after-X-removal'), isTrue);
      await waitUntil(
        () async => (await f.d.groups!.messagesOf(
          gid,
        )).any((m) => m.body == 'after-X-removal'),
        what: 'remaining D decrypts traffic under the rotated epoch',
      );
      await f.b.start();
      // A removed member may retain an old view without receiving any new
      // group data. Record that separately from the access-control criterion:
      // waiting for membership to change would never exercise the negative
      // receive/send probes on such a peer.
      final state = await f.b.groups!.stateOf(gid);
      E2eLog.line(
        'CASE54_STALE_MEMBERSHIP='
        '${state?.members.containsKey(f.a.identityNodeId.hex)}',
      );
      final posted = await f.b.groups!.postMessage(gid, 'removed-B-attempt');
      E2eLog.line('CASE54_REMOVED_B_LOCAL_POST=$posted');
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 20)) {
        expect(
          (await f.b.groups!.messagesOf(
            gid,
          )).any((m) => m.body == 'after-X-removal'),
          isFalse,
        );
        expect(
          (await f.c.groups!.messagesOf(
            gid,
          )).any((m) => m.body == 'removed-B-attempt'),
          isFalse,
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    },
    skip: gate.skip,
  );
}
