@Timeout(Duration(minutes: 30))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';

Future<Map<String, dynamic>> deviceInfo(ProcessDevice d) =>
    d.checked('/device_invite');

Future<String> physicalInvite(ProcessDevice d) async {
  final info = await deviceInfo(d);
  final link = DeviceLinkInvite.parse(info['invite'] as String);
  final status = await d.checked(
    '/p2p_status',
    query: {'peer': info['nodeId'] as String},
  );
  return BootstrapInvite(
    publicKey: link.device.publicKey,
    nonce: link.device.nonce,
    algo: link.device.algo,
    transport: 'quic://127.0.0.1:${status['listenPort']}',
  ).toUri();
}

Future<void> join(ProcessDevice from, ProcessDevice to) async {
  final result = await from.call(
    '/add_peer',
    query: {'uri': await physicalInvite(to)},
  );
  if (result['ok'] != true &&
      !'${result['error']}'.contains('alreadyRegistered')) {
    fail('${from.label} cannot join ${to.label}: $result');
  }
}

Future<String> linkProcesses(
  ProcessDevice source,
  ProcessDevice target, {
  E2eIdentity owner = E2eIdentity.x,
  Future<void> Function()? afterSnapshotSent,
}) async {
  final sourceIdentity = (await deviceInfo(source))['identity'];
  final info = await deviceInfo(target);
  expect(info['nodeId'], isNot((await deviceInfo(source))['nodeId']));
  final link = DeviceLinkInvite.parse(info['invite'] as String);
  final physical = BootstrapInvite.parse(await physicalInvite(target));
  final before = (await source.checked('/devices'))['deviceGroup'];
  final wrongSecret = await source.call(
    '/device_link_prepare',
    query: {
      'invite': DeviceLinkInvite(
        device: physical,
        document: link.document,
      ).toUri(),
    },
    body: (owner == E2eIdentity.x ? E2eIdentity.y : E2eIdentity.x).phrase,
  );
  expect(
    wrongSecret['ok'],
    isFalse,
    reason: 'another identity recovery secret must not authorize linking',
  );
  expect(
    (await source.checked('/devices'))['deviceGroup'],
    before,
    reason: 'a refused link must not create or change the device group',
  );
  final prepared = await source.checked(
    '/device_link_prepare',
    query: {
      'invite': DeviceLinkInvite(
        device: physical,
        document: link.document,
      ).toUri(),
    },
    body: owner.phrase,
  );
  await join(target, source);
  final adopted = await target.checked(
    '/device_adopt_prepare',
    body: prepared['token'] as String,
  );
  if (adopted['restarting'] == true) await target.restart();
  await join(source, target);
  await join(target, source);
  await source.checked('/device_snapshot_send');
  await afterSnapshotSent?.call();
  final group = prepared['deviceGroup'] as String;
  await waitUntil(
    () async => (await target.checked('/devices'))['deviceGroup'] == group,
    what: '${target.label} adopts $group in its own OS process',
    describe: () async => '${await target.checked('/devices')}',
    timeout: const Duration(minutes: 3),
  );
  final linked = await deviceInfo(target);
  expect(
    linked['identity'],
    sourceIdentity,
    reason: 'B must adopt exactly A identity, not only a group pointer',
  );
  expect(
    linked['nodeId'],
    info['nodeId'],
    reason: 'delegation must preserve B independent physical device key',
  );
  return group;
}

Future<String?> contactStatus(ProcessDevice d, String peer) async {
  final contacts = (await d.checked('/contacts'))['contacts'] as List;
  for (final c in contacts) {
    if (c['nodeId'] == peer) return c['status'] as String;
  }
  return null;
}

Future<void> introduceProcesses(ProcessDevice a, ProcessDevice c) async {
  await join(a, c);
  await join(c, a);
  final ai = (await deviceInfo(a))['identity'] as String;
  final ci = (await deviceInfo(c))['identity'] as String;
  await c.checked('/contact_request', query: {'peer': ai});
  await waitUntil(
    () async => await contactStatus(a, ci) == 'pendingIncoming',
    what: 'A sees C contact request across process boundaries',
    timeout: const Duration(minutes: 3),
  );
  await a.checked('/contact_accept', query: {'peer': ci});
  await waitUntil(
    () async => await contactStatus(c, ai) == 'accepted',
    what: 'C receives A acceptance across process boundaries',
  );
}

Future<List<Map<String, dynamic>>> rows(ProcessDevice d, String peer) async =>
    ((await d.checked(
              '/messages',
              query: {'peer': peer, 'limit': '1000'},
            ))['messages']
            as List)
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

Future<void> hasBody(ProcessDevice d, String peer, String body) => waitUntil(
  () async => (await rows(d, peer)).where((m) => m['body'] == body).length == 1,
  what: '${d.label} receives $body exactly once in its own process',
  describe: () async => '${await rows(d, peer)}',
  timeout: const Duration(minutes: 3),
);

void main() {
  final gate = E2eGate.read();
  for (final keepCOnline in [false, true]) {
    test(
      'isolated A/B/C: history, bidirectional messages, reconnect and ${keepCOnline ? "online C" : "offline"} revoke',
      () async {
        final f = await ProcessFleet.start(gate);
        addTearDown(f.dispose);
        final a = f.a, b = f.b, c = f.c;
        await introduceProcesses(a, c);
        final ai = (await deviceInfo(a))['identity'] as String;
        final ci = (await deviceInfo(c))['identity'] as String;
        await a.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'process-history'},
        );
        await hasBody(c, ai, 'process-history');
        await linkProcesses(a, b);
        await hasBody(b, ci, 'process-history');
        E2eLog.line(
          'PROCESS_CASE5_PASS: old history copied without a shared registry',
        );
        await c.checked(
          '/send_message',
          query: {'peer': ai, 'text': 'process-incoming'},
        );
        await hasBody(a, ci, 'process-incoming');
        await hasBody(b, ci, 'process-incoming');
        await a.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'process-outgoing'},
        );
        await hasBody(c, ai, 'process-outgoing');
        await hasBody(b, ci, 'process-outgoing');
        final outgoing = (await rows(
          a,
          ci,
        )).singleWhere((m) => m['body'] == 'process-outgoing');
        expect(
          (await rows(
            b,
            ci,
          )).singleWhere((m) => m['body'] == 'process-outgoing')['id'],
          outgoing['id'],
        );
        // Non-vacuity: C must have accepted authenticated traffic from B's actual
        // device key before that key is revoked.
        await b.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'process-B-before-revoke'},
        );
        await hasBody(c, ai, 'process-B-before-revoke');
        E2eLog.line('PROCESS_CASE2_3_8_PASS');

        final oldDevice = (await deviceInfo(b))['nodeId'] as String;
        await b.stop();
        await a.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'process-offline-B'},
        );
        await hasBody(c, ai, 'process-offline-B');
        await c.stop();
        await b.start();
        await hasBody(b, ci, 'process-offline-B');
        E2eLog.line(
          'PROCESS_RECONNECT_PASS: A online, C offline, new B process',
        );

        if (keepCOnline) {
          await c.start();
          await join(b, c);
          await b.checked(
            '/send_message',
            query: {'peer': ci, 'text': 'process-B-warm-online-revoke'},
          );
          await hasBody(c, ai, 'process-B-warm-online-revoke');
        }
        await b.stop();
        final revoked = await a.checked(
          '/device_revoke',
          query: {'peer': oldDevice},
          body: E2eIdentity.x.phrase,
        );
        expect(revoked['docRevoked'], isTrue);
        await b.start();
        if (!keepCOnline) await c.start();
        await join(a, c);
        await join(c, a);
        await a.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'process-after-revoke-control'},
        );
        await hasBody(c, ai, 'process-after-revoke-control');
        await c.checked(
          '/send_message',
          query: {'peer': ai, 'text': 'process-to-revoked-identity'},
        );
        await hasBody(a, ci, 'process-to-revoked-identity');
        await join(b, c);
        await b.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'process-revoked-B-attempt'},
        );
        await b.checked('/call_place', query: {'peer': ci});
        // C still holds the contact it knew before revoke. This send must not
        // appear at old B merely because C missed the revocation while offline.
        final observe = Stopwatch()..start();
        final violations = <String, int>{};
        while (observe.elapsed < const Duration(seconds: 60)) {
          if ((await c.checked('/call_state'))['call'] != null) {
            violations.putIfAbsent(
              'revoked B initiated a call on C',
              () => observe.elapsedMilliseconds,
            );
          }
          final old = await rows(b, ci);
          if (old.any(
            (m) =>
                m['body'] == 'process-to-revoked-identity' ||
                m['body'] == 'process-after-revoke-control',
          )) {
            violations.putIfAbsent(
              'old B received post-revoke data',
              () => observe.elapsedMilliseconds,
            );
          }
          if ((await rows(
            c,
            ai,
          )).any((m) => m['body'] == 'process-revoked-B-attempt')) {
            violations.putIfAbsent(
              'C accepted a post-revoke message signed by old B',
              () => observe.elapsedMilliseconds,
            );
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        E2eLog.line('PROCESS_REVOKE_VIOLATIONS_MS=$violations');
        expect(
          violations,
          isEmpty,
          reason:
              'post-revoke capabilities observed, including transient acceptance',
        );
        final oldInvite = (await deviceInfo(b))['invite'] as String;
        final relink = await a.call(
          '/device_link_prepare',
          query: {'invite': oldInvite},
          body: E2eIdentity.x.phrase,
        );
        expect(relink['ok'], isFalse);
        expect(
          '${relink['error']}'.toLowerCase(),
          anyOf(contains('tombston'), contains('revoked')),
        );
        E2eLog.line('PROCESS_REVOKE_RECEIVE_AND_OLD_RELINK_PASS');
      },
      skip: gate.skip,
    );
  }

  test(
    'isolated A/B/C: offline C sends before post-revoke master message',
    () async {
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final ai = (await deviceInfo(a))['identity'] as String;
      final ci = (await deviceInfo(c))['identity'] as String;
      final oldDevice = (await deviceInfo(b))['nodeId'] as String;
      // Preserve the contact and its P2P policy through restart. Do not
      // manually refresh it with a post-revoke A/C join or message from A.
      await c.checked('/contact_set', query: {'peer': ai, 'p2p': 'deny'});
      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'stale-C-before-revoke'},
      );
      await hasBody(c, ai, 'stale-C-before-revoke');
      await c.checked(
        '/send_message',
        query: {'peer': ai, 'text': 'stale-C-family-before-revoke'},
      );
      await hasBody(a, ci, 'stale-C-family-before-revoke');
      await hasBody(b, ci, 'stale-C-family-before-revoke');
      await b.stop();
      await c.stop();
      final revoked = await a.checked(
        '/device_revoke',
        query: {'peer': oldDevice},
        body: E2eIdentity.x.phrase,
      );
      expect(revoked['docRevoked'], isTrue);
      await b.start();
      await c.start();
      expect((await deviceInfo(b))['nodeId'], oldDevice);
      expect((await deviceInfo(b))['identity'], ai);
      expect(
        (await c.checked('/contact_info', query: {'peer': ai}))['p2pOverride'],
        'deny',
      );

      const first = 'stale-C-first-post-revoke-send';
      const attack = 'stale-C-revoked-B-attempt';
      final violations = <String, int>{};
      final observed = Stopwatch()..start();
      final watching = Completer<void>();
      var stop = false;
      Object? observationError;
      Future<void> observe() async {
        try {
          while (!stop) {
            for (final (device, peer, body, violation) in [
              (b, ci, first, 'old B received the first post-revoke send'),
              (c, ai, attack, 'C accepted a message signed by revoked B'),
            ]) {
              final result = await device.call(
                '/messages',
                query: {'peer': peer, 'limit': '1000'},
                timeout: const Duration(seconds: 5),
              );
              expect(result['ok'], isTrue);
              final messages = result['messages'] as List;
              if (messages.any((m) => m['body'] == body)) {
                violations.putIfAbsent(
                  violation,
                  () => observed.elapsedMilliseconds,
                );
              }
            }
            if (!watching.isCompleted) watching.complete();
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        } catch (error) {
          observationError = error;
          if (!watching.isCompleted) watching.completeError(error);
        }
      }

      final observer = observe();
      try {
        await watching.future.timeout(const Duration(seconds: 10));
        // No post-revoke A/C join or A application message precedes this.
        await c.checked('/send_message', query: {'peer': ai, 'text': first});
        await hasBody(a, ci, first);
        await join(b, c);
        await b.checked('/send_message', query: {'peer': ci, 'text': attack});
        final afterAttack = Stopwatch()..start();
        while (afterAttack.elapsed < const Duration(seconds: 60)) {
          if (observationError != null) throw observationError!;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      } finally {
        stop = true;
        await observer;
      }
      expect(observationError, isNull);
      expect(
        violations,
        isEmpty,
        reason: 'post-revoke delivery before master application traffic',
      );
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'stale-C-later-master-control'},
      );
      await hasBody(c, ai, 'stale-C-later-master-control');
      expect((await rows(b, ci)).any((m) => m['body'] == first), isFalse);
      E2eLog.line('PROCESS_STALE_C_FIRST_SEND_REVOKE_PASS');
    },
    skip: gate.skip,
  );

  test(
    'isolated A/B/C: warm C survives a transport partition during revoke',
    () async {
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final ai = (await deviceInfo(a))['identity'] as String;
      final ci = (await deviceInfo(c))['identity'] as String;
      final oldDevice = (await deviceInfo(b))['nodeId'] as String;
      final cNode = (await deviceInfo(c))['nodeId'] as String;
      final aNode = (await deviceInfo(a))['nodeId'] as String;
      await c.checked('/contact_set', query: {'peer': ai, 'p2p': 'deny'});
      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'warm-C-prime-from-B'},
      );
      await hasBody(c, ai, 'warm-C-prime-from-B');
      await c.checked(
        '/send_message',
        query: {'peer': ai, 'text': 'warm-C-prime-family'},
      );
      await hasBody(a, ci, 'warm-C-prime-family');
      await hasBody(b, ci, 'warm-C-prime-family');
      final documentKey = (await c.admin(gate.veilCli!, [
        'identity',
        'dht-key',
        ai,
      ])).trim();
      expect(documentKey, matches(RegExp(r'^[0-9a-f]{64}$')));
      Future<String?> document(ProcessDevice device) async {
        final result = await device.admin(gate.veilCli!, [
          'node',
          'dht',
          'get',
          documentKey,
        ]);
        return RegExp(
          r'^value: ([0-9a-f]+)$',
          multiLine: true,
        ).firstMatch(result)?.group(1);
      }

      Future<List<String>> cSessions() async =>
          (await c.admin(gate.veilCli!, ['sessions', 'list', '--verbose']))
              .split('\n')
              .where((line) => line.split('\t').length == 7)
              .where((line) => !line.startsWith('link_id\t'))
              .toList();
      expect(await cSessions(), isNotEmpty);
      final cPids = List<int>.of(c.ownedPids);
      final otherNodes = [
        aNode,
        oldDevice,
        for (final relay in f.cluster.nodes) relay.nodeIdHex!,
      ];
      // Ban both directions, including manually joined A/C and learned B/C
      // links. Banning relays alone would leave a false partition via QUIC.
      for (final node in otherNodes) {
        await c.admin(gate.veilCli!, ['peers', 'ban', node]);
      }
      for (final relay in f.cluster.nodes) {
        await f.cluster.admin(relay, ['peers', 'ban', cNode]);
      }
      await a.admin(gate.veilCli!, ['peers', 'ban', cNode]);
      await b.admin(gate.veilCli!, ['peers', 'ban', cNode]);
      await waitUntil(
        () async => (await cSessions()).isEmpty,
        what: 'warm C has zero native sessions while its process stays alive',
      );
      expect((await c.checked('/health'))['realStack'], isTrue);
      await b.stop();
      final revoked = await a.checked(
        '/device_revoke',
        query: {'peer': oldDevice},
        body: E2eIdentity.x.phrase,
      );
      expect(revoked['docRevoked'], isTrue);
      final currentDocument = await document(a);
      expect(currentDocument, isNotNull);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await cSessions(), isEmpty);
      expect(await document(c), isNot(currentDocument));
      expect(
        c.ownedPids,
        cPids,
        reason: 'C caches must survive in one process',
      );
      E2eLog.line('PROCESS_WARM_C_ZERO_SESSION_PARTITION_PASS');

      for (final node in otherNodes) {
        await c.admin(gate.veilCli!, ['peers', 'unban', node]);
      }
      for (final relay in f.cluster.nodes) {
        await f.cluster.admin(relay, ['peers', 'unban', cNode]);
      }
      await a.admin(gate.veilCli!, ['peers', 'unban', cNode]);
      await b.start();
      expect((await deviceInfo(b))['nodeId'], oldDevice);
      // First application traffic after reconnection comes from stale C.
      // Native current-document propagation is allowed, as in production.
      const first = 'warm-C-first-after-revoke';
      const attack = 'warm-C-revoked-B-attempt';
      await c.checked('/send_message', query: {'peer': ai, 'text': first});
      await hasBody(a, ci, first);
      final freshBeforeAttack = await document(c) == currentDocument;
      await join(b, c);
      await b.checked('/send_message', query: {'peer': ci, 'text': attack});
      // A disconnected peer cannot reject a revocation it has not learned.
      // Distinguish that propagation window from a warm-cache bypass AFTER
      // the fresh signed document is locally available. This observer performs
      // local DHT reads only: no forced fetch, cache flush or document injection.
      final earlyAttackAccepted = (await rows(
        c,
        ai,
      )).any((m) => m['body'] == attack);
      E2eLog.line(
        'PROCESS_WARM_C_RECONNECT_OBSERVATION '
        'freshBeforeAttack=$freshBeforeAttack '
        'earlyAttackAccepted=$earlyAttackAccepted',
      );
      if (freshBeforeAttack) expect(earlyAttackAccepted, isFalse);
      final reconnectWatch = Stopwatch()..start();
      var lastAttempt = Duration.zero;
      await waitUntil(
        () async {
          if (await document(c) == currentDocument) return true;
          if (reconnectWatch.elapsed - lastAttempt >=
              const Duration(seconds: 5)) {
            lastAttempt = reconnectWatch.elapsed;
            await b.checked(
              '/send_message',
              query: {'peer': ci, 'text': attack},
            );
          }
          return false;
        },
        what: 'warm C refreshes the document while old B keeps sending',
        timeout: const Duration(minutes: 2),
      );
      E2eLog.line(
        'PROCESS_WARM_C_CURRENT_DOCUMENT_BARRIER_PASS '
        'observedAfterMs=${reconnectWatch.elapsedMilliseconds}',
      );
      const afterFresh = 'warm-C-after-current-document';
      const attackFresh = 'warm-C-revoked-B-after-current-document';
      await c.checked('/send_message', query: {'peer': ai, 'text': afterFresh});
      await hasBody(a, ci, afterFresh);
      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': attackFresh},
      );
      final observing = Stopwatch()..start();
      do {
        expect(
          (await rows(b, ci)).any((m) => m['body'] == afterFresh),
          isFalse,
        );
        expect(
          (await rows(c, ai)).any((m) => m['body'] == attackFresh),
          isFalse,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } while (observing.elapsed < const Duration(seconds: 60));
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'warm-C-master-control'},
      );
      await hasBody(c, ai, 'warm-C-master-control');
      expect(c.ownedPids, cPids);
      E2eLog.line('PROCESS_WARM_C_PARTITION_REVOKE_PASS');
    },
    skip: gate.skip,
  );

  test(
    'isolated A/B/C: simultaneous call answers have one media endpoint',
    () async {
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final ai = (await deviceInfo(a))['identity'] as String;
      Map<String, dynamic>? ac, bc, cc;
      Future<void> sample() async {
        ac = (await a.checked('/call_state'))['call'] as Map<String, dynamic>?;
        bc = (await b.checked('/call_state'))['call'] as Map<String, dynamic>?;
        cc = (await c.checked('/call_state'))['call'] as Map<String, dynamic>?;
      }

      Map<String, Object?> brief(Map<String, dynamic>? call) => {
        'status': call?['status'],
        'peer': call?['peer'],
        'rx': (call?['mediaStats'] as Map?)?['rx_pkts'],
      };
      bool live(Map<String, dynamic>? call) =>
          call != null && call['status'] != 'ended';
      int received(Map<String, dynamic>? call) =>
          ((call?['mediaStats'] as Map?)?['rx_pkts'] as num?)?.toInt() ?? 0;
      await c.checked('/call_place', query: {'peer': ai});
      await waitUntil(
        () async {
          await sample();
          return ac?['status'] == 'ringing' && bc?['status'] == 'ringing';
        },
        what: 'both independent sibling processes ring',
        describe: () => 'A=${brief(ac)} B=${brief(bc)} C=${brief(cc)}',
      );
      await Future.wait([a.checked('/call_accept'), b.checked('/call_accept')]);
      await waitUntil(
        () async {
          await sample();
          return [ac, bc].where(live).length == 1 &&
              live(cc) &&
              received(cc) > 0 &&
              received(live(ac) ? ac : bc) > 0;
        },
        what: 'one accepted endpoint and bidirectional real media',
        describe: () => 'A=${brief(ac)} B=${brief(bc)} C=${brief(cc)}',
        timeout: const Duration(seconds: 40),
      );
      await (live(ac) ? a : b).checked('/call_hangup');
      await waitUntil(() async {
        await sample();
        return ![ac, bc, cc].any(live);
      }, what: 'the race call finishes everywhere');
    },
    skip: gate.mediaSkip,
  );
  test(
    'isolated A/B/C: abrupt sender crash preserves delivery and later mirror',
    () async {
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final ai = (await deviceInfo(a))['identity'] as String;
      final ci = (await deviceInfo(c))['identity'] as String;
      await b.stop();
      final started = DateTime.now();
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'crash-after-send'},
      );
      await a.stop(crash: true);
      E2eLog.line(
        'CASE13_FORCE_KILL: ${DateTime.now().difference(started).inMilliseconds}ms from send start',
      );
      await hasBody(c, ai, 'crash-after-send');
      await a.start();
      await b.start();
      await hasBody(b, ci, 'crash-after-send');
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'ratchet-after-crash'},
      );
      await hasBody(c, ai, 'ratchet-after-crash');
      await hasBody(b, ci, 'ratchet-after-crash');
      await c.checked(
        '/send_message',
        query: {'peer': ai, 'text': 'reply-after-crash'},
      );
      await hasBody(a, ci, 'reply-after-crash');
      await hasBody(b, ci, 'reply-after-crash');
      // Repeated fresh processes must resume persisted state without adding rows.
      await b.restart();
      await hasBody(b, ci, 'crash-after-send');
      await hasBody(b, ci, 'ratchet-after-crash');
      await hasBody(b, ci, 'reply-after-crash');
      final own = await rows(a, ci), sibling = await rows(b, ci);
      for (final body in [
        'crash-after-send',
        'ratchet-after-crash',
        'reply-after-crash',
      ]) {
        expect(
          sibling.singleWhere((m) => m['body'] == body)['id'],
          own.singleWhere((m) => m['body'] == body)['id'],
        );
      }
      E2eLog.line('PROCESS_CASE13_CRASH_AND_RECONNECT_PASS');
    },
    skip: gate.skip,
  );
}
