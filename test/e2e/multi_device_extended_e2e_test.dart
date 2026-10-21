@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/data/veil_stack.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

/// Live extensions of the numbered checklist. No direct journal injection:
/// actions enter through the same services as the UI, with real encrypted
/// storage and native nodes. These tests do not certify cross-process device
/// authorization: see the fixture's process-global document-registry caveat.
void main() {
  final gate = E2eGate.read();
  bool concurrentRow(Message m) =>
      m.body.startsWith('alternate-') || m.body.startsWith('simultaneous-');
  bool backlogRow(Message m) =>
      m.body.startsWith('burst-') || m.body == 'during-reconnect';

  Future<E2eFleet> ready() async {
    final f = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
    addTearDown(f.dispose);
    await f.linkDevice(master: f.a, target: f.b);
    await f.introduce(f.a, f.c);
    await waitUntil(
      () async =>
          (await f.b.storage.getContact(f.c.identityNodeId))?.status ==
          ContactStatus.accepted,
      what: 'B learns accepted contact C',
    );
    return f;
  }

  Future<void> holds(E2eDevice d, NodeId peer, String body) => waitUntil(
    () async => (await d.conversation(peer)).contains(body),
    what: '${d.label} holds $body',
    describe: () async => '${await d.conversation(peer)}',
    timeout: const Duration(minutes: 3),
  );

  test(
    'case 12 — concurrent writers converge on six messages in the same order',
    () async {
      final f = await ready();
      final peer = f.c.identityNodeId;
      for (var i = 0; i < 4; i++) {
        expect(
          await (i.isEven ? f.a : f.b).messaging.sendText(peer, 'alternate-$i'),
          isTrue,
        );
      }
      await Future.wait([
        f.a.messaging.sendText(peer, 'simultaneous-A'),
        f.b.messaging.sendText(peer, 'simultaneous-B'),
      ]);
      await holds(f.c, f.a.identityNodeId, 'simultaneous-B');
      await holds(f.a, peer, 'simultaneous-B');
      await holds(f.b, peer, 'simultaneous-A');

      await waitUntil(() async {
        final a = (await f.a.conversationRows(
          peer,
        )).where(concurrentRow).toList();
        final b = (await f.b.conversationRows(
          peer,
        )).where(concurrentRow).toList();
        final c = (await f.c.conversationRows(
          f.a.identityNodeId,
        )).where(concurrentRow).toList();
        return a.length == 6 &&
            b.length == 6 &&
            c.length == 6 &&
            a.map((m) => m.id).join('|') == b.map((m) => m.id).join('|') &&
            a.map((m) => m.id).join('|') == c.map((m) => m.id).join('|');
      }, what: 'A/B/C agree on all six concurrent-message IDs and their order');
    },
    skip: gate.skip,
  );

  test(
    'cases 14/15/16 — 100-message interrupted catch-up and a reconnect send',
    () async {
      final f = await ready();
      final peer = f.c.identityNodeId;
      await f.b.stop();
      final offline = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        expect(await f.a.messaging.sendText(peer, 'burst-$i'), isTrue);
      }
      await holds(f.c, f.a.identityNodeId, 'burst-99');
      await f.b.start();
      await waitUntil(
        () async =>
            (await f.b.conversation(
              peer,
            )).where((s) => s.startsWith('burst-')).length >=
            40,
        what: 'B receives at least 40 backlog rows before interruption',
        interval: const Duration(milliseconds: 10),
        timeout: const Duration(minutes: 5),
        describe: () async =>
            'B=${(await f.b.conversation(peer)).where((s) => s.startsWith("burst-")).length}/100 '
            'B journal=${(await f.b.snapshot()).notes} '
            'A queued=${(await f.a.storage.pendingOutboxFrames()).where((frame) => frame.peerHex == f.b.deviceNodeId.hex).length}',
      );
      final partial = (await f.b.conversation(
        peer,
      )).where((s) => s.startsWith('burst-')).length;
      E2eLog.line('case 16: interrupt after $partial/100 rows');
      // Keep this distinction in the report even if catch-up is atomic or
      // faster than the observation: that run does not prove case 16.
      E2eLog.line(
        partial < 100
            ? 'CASE16_INTERRUPTED_PARTIAL=$partial'
            : 'CASE16_NOT_EXERCISED: all rows arrived before interruption',
      );
      await f.b.stop();
      final restarting = f.b.start();
      expect(await f.a.messaging.sendText(peer, 'during-reconnect'), isTrue);
      await restarting;
      await holds(f.b, peer, 'during-reconnect');
      await waitUntil(
        () async =>
            (await f.b.conversation(
              peer,
            )).where((s) => s.startsWith('burst-')).length ==
            100,
        what: 'all 100 backlog rows arrive after the interrupted reconnect',
        timeout: const Duration(minutes: 5),
      );
      E2eLog.line(
        'case 15: offline plus recovery ${offline.elapsedMilliseconds}ms',
      );
      await waitUntil(
        () async {
          final a = (await f.a.conversationRows(
            peer,
          )).where(backlogRow).toList();
          final b = (await f.b.conversationRows(
            peer,
          )).where(backlogRow).toList();
          final c = (await f.c.conversationRows(
            f.a.identityNodeId,
          )).where(backlogRow).toList();
          return a.length == 101 &&
              b.length == 101 &&
              c.length == 101 &&
              a.map((m) => m.id).join('|') == b.map((m) => m.id).join('|') &&
              a.map((m) => m.id).join('|') == c.map((m) => m.id).join('|');
        },
        what: 'A/B/C agree on all 101 IDs and their order',
        timeout: const Duration(minutes: 5),
      );
      for (final d in [f.a, f.b, f.c]) {
        final rows = await d.conversationRows(
          d == f.c ? f.a.identityNodeId : peer,
        );
        expect(rows.where(backlogRow).map((m) => m.id).toSet(), hasLength(101));
      }
    },
    skip: gate.skip,
  );

  test(
    'cases 17/18/19/50/51 — reads, reactions, edits, replies, pins and contact preferences',
    () async {
      final f = await ready();
      final peer = f.c.identityNodeId;
      await f.c.messaging.sendText(f.a.identityNodeId, 'read-on-A');
      await holds(f.b, peer, 'read-on-A');
      await f.a.messaging.markRead(peer.hex);
      final firstRead = await f.a.storage.readMarker(peer.hex);
      expect(firstRead, greaterThan(0));
      await waitUntil(
        () async => await f.b.storage.readMarker(peer.hex) >= firstRead,
        what: 'reading on A advances B read marker',
      );
      await f.c.messaging.sendText(f.a.identityNodeId, 'read-on-B');
      await holds(f.b, peer, 'read-on-B');
      await f.b.messaging.markRead(peer.hex);
      final secondRead = await f.b.storage.readMarker(peer.hex);
      await waitUntil(
        () async => await f.a.storage.readMarker(peer.hex) >= secondRead,
        what: 'reading on B advances A read marker',
      );

      await f.a.messaging.sendText(peer, 'editable');
      await holds(f.b, peer, 'editable');
      await holds(f.c, f.a.identityNodeId, 'editable');
      final id = (await f.a.conversationRows(
        peer,
      )).singleWhere((m) => m.body == 'editable').id;
      await f.a.messaging.sendReaction(peer, id, '👍');
      await waitUntil(
        () async =>
            (await f.b.messaging.loadReactions(
                  peer.hex,
                ))[id]?.values.contains('👍') ==
                true &&
            (await f.c.messaging.loadReactions(
                  f.a.identityNodeId.hex,
                ))[id]?.values.contains('👍') ==
                true,
        what: 'own reaction reaches sibling and counterpart',
      );
      await f.a.messaging.sendReaction(peer, id, '');
      await waitUntil(
        () async =>
            (await f.b.messaging.loadReactions(
                  peer.hex,
                ))[id]?.values.contains('👍') !=
                true &&
            (await f.c.messaging.loadReactions(
                  f.a.identityNodeId.hex,
                ))[id]?.values.contains('👍') !=
                true,
        what: 'reaction removal reaches sibling and counterpart',
      );
      await f.a.messaging.editOwnMessage(id, 'edited');
      await holds(f.b, peer, 'edited');
      await holds(f.c, f.a.identityNodeId, 'edited');
      await f.b.messaging.sendText(peer, 'reply-from-B', replyToId: id);
      await holds(f.a, peer, 'reply-from-B');
      await holds(f.c, f.a.identityNodeId, 'reply-from-B');
      for (final d in [f.a, f.b, f.c]) {
        final rows = await d.conversationRows(
          d == f.c ? f.a.identityNodeId : peer,
        );
        expect(
          rows.singleWhere((m) => m.body == 'reply-from-B').replyToId,
          id,
          reason: '${d.label} lost the reply target',
        );
      }
      await f.a.messaging.sendText(
        peer,
        'forwarded-from-A',
        forwardedFrom: 'Original author',
      );
      await holds(f.b, peer, 'forwarded-from-A');
      await holds(f.c, f.a.identityNodeId, 'forwarded-from-A');
      for (final d in [f.a, f.b, f.c]) {
        final rows = await d.conversationRows(
          d == f.c ? f.a.identityNodeId : peer,
        );
        expect(
          rows.singleWhere((m) => m.body == 'forwarded-from-A').forwardedFrom,
          'Original author',
          reason: '${d.label} lost forwarded attribution',
        );
      }
      await f.a.messaging.setPinnedMessage(peer, id);
      await f.a.messaging.setContactName(peer, 'Synced C');
      await f.a.messaging.setContactArchived(peer, true);
      await f.a.messaging.setContactPinned(peer, true);
      await f.a.messaging.setContactMuted(peer, true);
      await waitUntil(() async {
        final c = await f.b.storage.getContact(peer);
        return await f.b.storage.getSetting('pin:${peer.hex}') == id &&
            c?.name == 'Synced C' &&
            c?.archived == true &&
            c?.pinned == true &&
            c?.mutedUntil != null;
      }, what: 'B applies pin, contact name, archive, chat pin and mute');
      await f.a.messaging.blockContact(peer);
      await waitUntil(
        () async =>
            (await f.b.storage.getContact(peer))?.status ==
            ContactStatus.blocked,
        what: 'blocking C on A blocks it on B',
      );
      await f.b.restart();
      expect(
        (await f.b.storage.getContact(peer))?.status,
        ContactStatus.blocked,
      );
      expect(await f.b.storage.getSetting('pin:${peer.hex}'), id);
    },
    skip: gate.skip,
  );

  test(
    'cases 7/33/34 — image and 4 MiB file survive holder shutdown and B restart',
    () async {
      final f = await ready();
      final peer = f.c.identityNodeId;
      final fixtures = <String, Uint8List>{
        'image-fixture.png': base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aMsAAAAAASUVORK5CYII=',
        ),
        'large-fixture.bin': Uint8List.fromList(
          List.generate(4 * 1024 * 1024, (i) => (i * 31 + 7) & 255),
        ),
      };
      for (final fixture in fixtures.entries) {
        final data = fixture.value;
        final name = fixture.key;
        await f.a.messaging.sendFile(peer, data, name);
        await waitUntil(
          () async =>
              (await f.b.conversationRows(peer)).any((m) => m.fileName == name),
          what: 'B mirrors $name',
        );
        final row = (await f.b.conversationRows(
          peer,
        )).singleWhere((m) => m.fileName == name);
        final cid = row.fileContentId ?? row.fileId;
        expect(cid, isNotNull);
        if (!await f.b.storage.hasFile(cid!)) {
          await f.b.messaging.downloadContent(f.a.deviceNodeId, cid);
        }
        await waitUntil(
          () => f.b.storage.hasFile(cid),
          what: 'B gets verified $name bytes',
          timeout: const Duration(minutes: 5),
        );
        expect(await f.b.storage.loadFile(cid), data);
      }
      await f.a.stop();
      await f.c.stop();
      await f.b.restart();
      for (final row in await f.b.conversationRows(peer)) {
        final cid = row.fileContentId ?? row.fileId;
        if (cid == null) continue;
        final bytes = await f.b.storage.loadFile(cid);
        expect(bytes, isNotNull);
        expect(bytes!.length, row.fileSize);
        expect(bytes, fixtures[row.fileName]);
      }
    },
    skip: gate.skip,
  );

  test(
    'case 37 — decline on either sibling ends the call for the identity',
    () async {
      final f = await ready();
      for (final answering in [f.a, f.b]) {
        await f.c.calls.placeCall(
          f.a.identityNodeId,
          const CallMedia(audio: true),
        );
        await waitUntil(
          () =>
              f.a.calls.current?.status == CallStatus.ringing &&
              f.b.calls.current?.status == CallStatus.ringing,
          what: 'both devices ring before ${answering.label} declines',
        );
        await answering.calls.reject();
        await waitUntil(
          () => ![f.a, f.b, f.c].any((d) => d.calls.current?.isLive ?? false),
          what: 'decline on ${answering.label} stops all three devices',
        );
      }
    },
    skip: gate.skip,
  );

  test(
    'cases 38/39/41 — joining during ringing and reconnecting after answer',
    () async {
      final f = await ready();
      await f.b.stop();
      await f.c.calls.placeCall(
        f.a.identityNodeId,
        const CallMedia(audio: true),
      );
      await waitUntil(
        () => f.a.calls.current?.status == CallStatus.ringing,
        what: 'A rings while B is offline',
      );
      await f.b.start();
      await waitUntil(
        () => f.b.calls.current?.status == CallStatus.ringing,
        what: 'reconnecting B joins the still-ringing call',
        timeout: const Duration(seconds: 40),
      );
      await f.a.calls.accept();
      await waitUntil(
        () =>
            f.c.calls.current?.status == CallStatus.active ||
            f.c.calls.current?.status == CallStatus.connecting,
        what: 'C receives A answer',
      );
      await f.b.restart();
      final late = Stopwatch()..start();
      while (late.elapsed < const Duration(seconds: 15)) {
        expect(f.b.calls.current?.status, isNot(CallStatus.ringing));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await f.a.calls.hangup();
      await waitUntil(
        () => !(f.c.calls.current?.isLive ?? false),
        what: 'C sees end before the answer race',
      );
    },
    skip: gate.mediaSkip,
  );

  test(
    'case 40 — simultaneous answers choose one active endpoint',
    () async {
      final f = await ready();
      await f.c.calls.placeCall(
        f.a.identityNodeId,
        const CallMedia(audio: true),
      );
      await waitUntil(
        () =>
            f.a.calls.current?.status == CallStatus.ringing &&
            f.b.calls.current?.status == CallStatus.ringing,
        what: 'A and B ring for simultaneous answer',
      );
      await Future.wait([f.a.calls.accept(), f.b.calls.accept()]);
      await waitUntil(
        () {
          final live = [
            f.a,
            f.b,
          ].where((d) => d.calls.current?.isLive ?? false).length;
          return live == 1 &&
              (f.c.calls.current?.isLive ?? false) &&
              f.c.calls.current?.status != CallStatus.dialing;
        },
        what: 'one and only one sibling wins the answer race',
        describe: () =>
            'A=${f.a.calls.current?.status} B=${f.b.calls.current?.status} '
            'C=${f.c.calls.current?.status}',
        timeout: const Duration(seconds: 30),
      );
      final winner = (f.a.calls.current?.isLive ?? false) ? f.a : f.b;
      await winner.calls.hangup();
      await waitUntil(
        () => ![f.a, f.b, f.c].any((d) => d.calls.current?.isLive ?? false),
        what: 'all devices finish the race call',
      );
      await waitUntil(
        () async =>
            (await f.a.storage.callLogEntries()).isNotEmpty &&
            (await f.b.storage.callLogEntries()).isNotEmpty,
        what: 'both siblings persist synchronized call history',
      );
    },
    skip: gate.mediaSkip,
  );

  test(
    'cases 7/33/35 — offline B retrieves a file with only C online',
    () async {
      final f = await ready();
      final aId = f.a.identityNodeId;
      final cId = f.c.identityNodeId;
      final bytes = Uint8List.fromList(
        List.generate(150 * 1024, (i) => (i * 17) & 255),
      );
      await f.b.stop();
      await f.a.messaging.sendFile(cId, bytes, 'only-C-source.bin');
      await waitUntil(
        () async => (await f.c.conversationRows(
          aId,
        )).any((m) => m.fileName == 'only-C-source.bin'),
        what: 'C receives the file metadata',
      );
      final atC = (await f.c.conversationRows(
        aId,
      )).singleWhere((m) => m.fileName == 'only-C-source.bin');
      final cid = atC.fileContentId ?? atC.fileId;
      expect(cid, isNotNull);
      await waitUntil(
        () => f.c.storage.hasFile(cid!),
        what: 'C holds all verified source bytes',
      );
      expect(await f.c.storage.loadFile(cid!), bytes);
      await f.a.stop();
      await f.b.start();
      await waitUntil(
        () async => (await f.b.conversationRows(
          cId,
        )).any((m) => m.fileName == 'only-C-source.bin'),
        what: 'B recovers outgoing file metadata with A offline',
        timeout: const Duration(minutes: 3),
      );
      final atB = (await f.b.conversationRows(
        cId,
      )).singleWhere((m) => m.fileName == 'only-C-source.bin');
      expect(atB.id, atC.id);
      expect(atB.direction, MessageDirection.outgoing);
      final bCid = atB.fileContentId ?? atB.fileId;
      expect(bCid, isNotNull);
      if (!await f.b.storage.hasFile(bCid!)) {
        await f.b.messaging.downloadContent(f.c.deviceNodeId, bCid);
      }
      await waitUntil(
        () => f.b.storage.hasFile(bCid),
        what: 'B gets the file from C with A offline',
        timeout: const Duration(minutes: 3),
      );
      expect(await f.b.storage.loadFile(bCid), bytes);
      E2eLog.line('CASE35_ONLY_C_HOLDER_BYTES_VERIFIED');
    },
    skip: gate.skip,
  );

  test('cases 56/57 — expired history and a reconnect near expiry', () async {
    final f = await ready();
    final peer = f.c.identityNodeId;
    await f.a.messaging.setContactDisappearing(peer, 3);
    await waitUntil(
      () async =>
          (await f.b.messaging.disappearingOf(peer)).ttlSeconds == 3 &&
          (await f.c.messaging.disappearingOf(f.a.identityNodeId)).ttlSeconds ==
              3,
      what: 'the short TTL is agreed on A/B/C',
    );
    await f.b.stop();
    await f.c.messaging.sendText(
      f.a.identityNodeId,
      'already-expired-at-reconnect',
    );
    await holds(f.a, peer, 'already-expired-at-reconnect');
    await Future<void>.delayed(const Duration(seconds: 5));
    await f.a.messaging.sweepDisappearing(peer);
    await f.b.start();
    await waitUntil(() async {
      await f.b.messaging.sweepDisappearing(peer);
      final a = await f.a.snapshot();
      final b = await f.b.snapshot();
      return a.bundleDigest == b.bundleDigest;
    }, what: 'B catches up the device journal after the message TTL');
    await f.b.messaging.sweepDisappearing(peer);
    expect(
      await f.b.conversation(peer),
      isNot(contains('already-expired-at-reconnect')),
    );
    E2eLog.line('CASE56_EXPIRED_HISTORY_ABSENT_AFTER_SWEEP');

    await f.a.messaging.setContactDisappearing(peer, 30);
    await waitUntil(
      () async =>
          (await f.b.messaging.disappearingOf(peer)).ttlSeconds == 30 &&
          (await f.c.messaging.disappearingOf(f.a.identityNodeId)).ttlSeconds ==
              30,
      what: 'the next TTL is agreed on A/B/C',
    );
    await f.b.stop();
    await f.c.messaging.sendText(
      f.a.identityNodeId,
      'near-expiry-at-reconnect',
    );
    await holds(f.a, peer, 'near-expiry-at-reconnect');
    final row = (await f.a.conversationRows(
      peer,
    )).singleWhere((m) => m.body == 'near-expiry-at-reconnect');
    final expiry = row.timestamp.add(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(seconds: 20));
    await f.b.start();
    var seenBeforeExpiry = false;
    while (DateTime.now().isBefore(expiry)) {
      seenBeforeExpiry |= (await f.b.conversation(peer)).contains(row.body);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    E2eLog.line('CASE57_LIVE_COPY_OBSERVED=$seenBeforeExpiry');
    expect(
      seenBeforeExpiry,
      isTrue,
      reason: 'B must actually receive the message before it expires',
    );
    await waitUntil(() async {
      for (final d in [f.a, f.b, f.c]) {
        await d.messaging.sweepDisappearing(
          d == f.c ? f.a.identityNodeId : peer,
        );
      }
      return !(await f.b.conversation(peer)).contains(row.body) &&
          !(await f.a.conversation(peer)).contains(row.body) &&
          !(await f.c.conversation(f.a.identityNodeId)).contains(row.body);
    }, what: 'the near-expiry message is absent everywhere after expiry');
  }, skip: gate.skip);

  test('cases 52/53 — pre-link group history and epoch key reach B', () async {
    final f = await E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']);
    addTearDown(f.dispose);
    await f.introduce(f.a, f.c);
    final gid = await f.a.groups!.createGroup('Multi-device group');
    expect(
      await f.a.groups!.addControlOp(
        gid,
        ControlOp.addMember,
        target: f.c.identityNodeId,
        role: GroupRole.member,
      ),
      isTrue,
    );
    await waitUntil(
      () async => await f.c.groups!.load(gid) != null,
      what: 'C receives the group membership',
    );
    expect(await f.a.groups!.postMessage(gid, 'group-before-B'), isTrue);
    await waitUntil(
      () async => (await f.c.groups!.messagesOf(
        gid,
      )).any((m) => m.body == 'group-before-B'),
      what: 'C reads group history',
    );
    await f.linkDevice(master: f.a, target: f.b);
    await waitUntil(
      () async => (await f.b.groups!.messagesOf(
        gid,
      )).any((m) => m.body == 'group-before-B'),
      what: 'newly linked B decrypts group history and obtains its epoch key',
    );
    expect(await f.b.groups!.postMessage(gid, 'group-from-B'), isTrue);
    await waitUntil(
      () async =>
          (await f.a.groups!.messagesOf(
            gid,
          )).any((m) => m.body == 'group-from-B') &&
          (await f.c.groups!.messagesOf(
            gid,
          )).any((m) => m.body == 'group-from-B'),
      what: 'B group message reaches A and C',
    );
    for (final d in [f.a, f.b, f.c]) {
      final rows = await d.groups!.messagesOf(gid);
      expect(rows.where((m) => m.body == 'group-before-B'), hasLength(1));
      expect(rows.where((m) => m.body == 'group-from-B'), hasLength(1));
    }
  }, skip: gate.skip);

  test(
    'cases 26/28/29/30 — offline revoke tombstones B and rejects old-device relinking',
    () async {
      final f = await ready();
      final bDevice = f.b.deviceNodeId;
      await f.b.stop();
      await f.c.stop();
      final result = await RealVeilStack.revokeDeviceFromDocument(
        f.a.storage,
        secret: f.a.identity.phrase,
        deviceId: bDevice.bytes,
        stagingBase: f.root.path,
      );
      expect(result.keyIsRetired, isTrue);
      await f.a.stack.refreshSovereignIdentity(f.a.storage);
      final signer = await f.a.groups!.openLocalSovereign(f.a.identity.phrase);
      try {
        expect(
          await f.a.groups!.revokeDevice(bDevice, sovereign: signer),
          isTrue,
        );
      } finally {
        signer.close();
      }
      expect(await f.a.groups!.isMyDevice(bDevice), isFalse);
      expect(
        (await f.a.storage.pendingOutboxFrames()).where(
          (frame) => frame.peerHex == bDevice.hex,
        ),
        isEmpty,
      );
      await f.b.start();
      await f.c.start();
      await f.a.messaging.sendText(f.c.identityNodeId, 'after-B-revoked');
      await holds(f.c, f.a.identityNodeId, 'after-B-revoked');
      final window = Stopwatch()..start();
      while (window.elapsed < const Duration(seconds: 30)) {
        expect(
          await f.b.conversation(f.c.identityNodeId),
          isNot(contains('after-B-revoked')),
        );
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      await expectLater(
        f.linkDevice(master: f.a, target: f.b),
        throwsA(isA<TombstonedDeviceException>()),
      );
      // The shared native registry can help these nodes learn the tombstone.
      // This proves local removal and no mirror/relink with the old key, NOT
      // cross-process propagation or cryptographic rejection on a stale C.
    },
    skip: gate.skip,
  );

  test(
    'case 47 — three devices of X mirror one message without duplicates',
    () async {
      final f = await E2eFleet.start(
        gate: gate,
        labels: const ['A', 'B', 'C', 'E'],
      );
      addTearDown(f.dispose);
      final e = f.devices['E']!;
      expect({
        f.a.deviceNodeId,
        f.b.deviceNodeId,
        e.deviceNodeId,
      }, hasLength(3));
      await f.linkDevice(master: f.a, target: f.b);
      await f.linkDevice(master: f.a, target: e);
      await f.introduce(f.a, f.c);
      await f.c.messaging.sendText(f.a.identityNodeId, 'three-X-devices');
      for (final d in [f.a, f.b, e]) {
        await holds(d, f.c.identityNodeId, 'three-X-devices');
        expect(
          (await d.conversationRows(
            f.c.identityNodeId,
          )).where((m) => m.body == 'three-X-devices'),
          hasLength(1),
        );
      }
    },
    skip: gate.skip,
  );
}
