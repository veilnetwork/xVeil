@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/message_edit.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'isolated A/B/C: peer recovers 100 equal-revision edits while A is offline',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_PEER_ECHO_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'same_identity_devices': 2,
        'separate_processes': true,
        'local_network_only': true,
        'controlled_container_seed_while_stopped': true,
        'production_fault_switch_added': false,
        'anonymous': Platform.environment['XVEIL_E2E_ANONYMOUS'] == '1',
        'messages': 100,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      try {
        await base.introduceProcesses(a, c);
        await base.linkProcesses(a, b);
        await base.join(b, c);
        await base.join(c, b);
        final aInfo = await base.deviceInfo(a);
        final bInfo = await base.deviceInfo(b);
        final cInfo = await base.deviceInfo(c);
        final identity = aInfo['identity'] as String;
        final author = aInfo['nodeId'] as String;
        final peer = cInfo['identity'] as String;
        expect(
          (bInfo['nodeId'] as String).substring(0, 8),
          isNot(identity.substring(0, 8)),
          reason:
              'the diagnostic prefixes must distinguish B from its identity',
        );
        Future<void> cryptoSnapshot(
          String stage,
          List<ProcessDevice> devices,
        ) async {
          if (evidence == null) return;
          final states = <String, Object?>{};
          final authorization = <String, Object?>{};
          for (final device in devices) {
            states[device.label] = await device.checked('/ratchet_positions');
            final nonce = '$stage-${device.label}';
            final request = File('${device.dir.path}/storage-inspect.new');
            await request.writeAsString(
              jsonEncode({
                'nonce': nonce,
                'peer': peer,
                'prefix': '',
                'authorizationOnly': true,
                'identity': identity,
                'physical': bInfo['nodeId'],
              }),
            );
            await request.rename('${device.dir.path}/storage-inspect.json');
            await waitUntil(
              () async {
                final response = File(
                  '${device.dir.path}/storage-inspected.json',
                );
                if (!await response.exists()) return false;
                final value = jsonDecode(await response.readAsString()) as Map;
                if (value['nonce'] != nonce) return false;
                authorization[device.label] = value['authorization'];
                return true;
              },
              what: 'private authorization snapshot',
              timeout: const Duration(seconds: 20),
            );
          }
          if (stage == 'after-offline-recovery' ||
              stage == 'after-online-recovery') {
            final conversations = (states['C'] as Map)['conversations'] as List;
            expect(
              conversations.where(
                (row) =>
                    row['peer'] == (bInfo['nodeId'] as String).substring(0, 8),
              ),
              isEmpty,
              reason:
                  'a reply must not create a ratchet under B physical address',
            );
            result['reply_ratchets_keep_identity_name'] = true;
          }
          // Runtime identifiers and hashed chain positions stay private.
          await File('$evidence/crypto-$stage-private.json').writeAsString(
            jsonEncode({
              'names': {'A': aInfo, 'B': bInfo, 'C': cInfo},
              'states': states,
              'authorization': authorization,
            }),
          );
        }

        await b.checked(
          '/send_message',
          query: {'peer': peer, 'text': 'echo-preflight'},
        );
        await base.hasBody(c, identity, 'echo-preflight');
        await cryptoSnapshot('before-restart', [a, b, c]);
        for (final device in [a, b, c]) {
          await device.stop();
        }
        expect(
          ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
          isTrue,
        );
        final winners = <String, String>{}, losers = <String, String>{};
        for (var i = 0; i < 100; i++) {
          final values = ['left-$i', 'right-$i']
            ..sort(
              (x, y) => messageEditContentHash(
                x,
                const [],
              ).compareTo(messageEditContentHash(y, const [])),
            );
          final id = 'echo-conflict-${i.toString().padLeft(3, '0')}';
          winners[id] = values.last;
          losers[id] = values.first;
        }
        final at = DateTime.now().subtract(const Duration(minutes: 5));
        Future<HiddenVolumeStorage> open(ProcessDevice device) async {
          final storage = HiddenVolumeStorage.async(
            workerSpaceOpener('${device.dir.path}/store.hv'),
          );
          expect(
            await storage.open(password: 'e2e-${device.label}-password'),
            isTrue,
          );
          return storage;
        }

        for (final device in [a, b, c]) {
          final storage = await open(device);
          final conversation = device == c ? identity : peer;
          try {
            // Keep exactly 100 visible outgoing rows on B: its first request
            // must exercise the complete hash inventory, not a smaller window.
            for (final old in await storage.loadMessages(conversation)) {
              await storage.deleteMessage(conversation, old.id);
            }
            var index = 0;
            for (final id in winners.keys) {
              await storage.appendMessage(
                Message(
                  id: id,
                  conversationId: conversation,
                  direction: device == c
                      ? MessageDirection.incoming
                      : MessageDirection.outgoing,
                  body: 'original-$index',
                  timestamp: at.add(Duration(seconds: index)),
                  status: MessageStatus.delivered,
                  author: device == c ? identity : author,
                  seq: 100 + index,
                  positionVerified: true,
                ),
              );
              await storage.editMessage(
                conversation,
                id,
                device == b ? losers[id]! : winners[id]!,
                seq: 1000,
              );
              index++;
            }
          } finally {
            await storage.close();
          }
        }
        var nonce = 0;
        var selectedPrefix = 'echo-conflict-';
        DateTime? nudgedAt;
        Future<Map<String, dynamic>> inspect({bool reconcile = false}) async {
          final token = ++nonce;
          final request = File('${b.dir.path}/storage-inspect.new');
          await request.writeAsString(
            jsonEncode({
              'nonce': token,
              'peer': peer,
              'prefix': selectedPrefix,
              'reconcile': reconcile,
            }),
          );
          await request.rename('${b.dir.path}/storage-inspect.json');
          final response = File('${b.dir.path}/storage-inspected.json');
          Map<String, dynamic>? state;
          await waitUntil(
            () async {
              if (!await response.exists()) return false;
              final value =
                  jsonDecode(await response.readAsString())
                      as Map<String, dynamic>;
              if (value['nonce'] != token) return false;
              state = value;
              return true;
            },
            what: 'live worker reports aggregate edit provenance',
            timeout: const Duration(seconds: 10),
          );
          return state!;
        }

        Future<bool> allBodies(
          ProcessDevice device,
          String conversation,
        ) async {
          final messages = (await base.rows(
            device,
            conversation,
          )).where((message) => winners.containsKey(message['id'])).toList();
          return messages.length == winners.length &&
              messages.map((message) => message['id']).toSet().length ==
                  winners.length &&
              jsonEncode(messages.map((message) => message['id']).toList()) ==
                  jsonEncode(winners.keys.toList()) &&
              messages.every(
                (message) => message['body'] == winners[message['id']],
              );
        }

        await c.start();
        await b.start();
        await cryptoSnapshot('after-restart', [b, c]);
        final started = DateTime.now();
        var sampled = false;
        try {
          await waitUntil(
            () async {
              final now = DateTime.now();
              final nudge =
                  nudgedAt == null ||
                  now.difference(nudgedAt!) >= const Duration(seconds: 10);
              if (nudge) nudgedAt = now;
              final state = await inspect(reconcile: nudge);
              if (!sampled &&
                  now.difference(started) >= const Duration(seconds: 20)) {
                sampled = true;
                await cryptoSnapshot('during-recovery', [b, c]);
              }
              return state['count'] == 100 &&
                  state['reflectedEdits'] == 100 &&
                  await allBodies(b, peer);
            },
            what: 'B recovers all 100 conflicting edits solely from C',
            timeout: const Duration(minutes: 3),
          );
        } catch (_) {
          await cryptoSnapshot('failed-recovery', [b, c]);
          rethrow;
        }
        result['recovery_seconds'] =
            DateTime.now().difference(started).inMilliseconds / 1000;
        result['a_offline_during_peer_recovery'] = true;
        result['full_hash_window_recovered'] = true;
        await cryptoSnapshot('after-offline-recovery', [b, c]);
        expect(await allBodies(c, identity), isTrue);
        await b.stop();
        await c.stop();
        var held = await open(b);
        try {
          final messages = (await held.loadMessages(
            peer,
          )).where((message) => winners.containsKey(message.id)).toList();
          expect(messages, hasLength(100));
          expect(
            messages.every(
              (message) =>
                  message.reflectedEdit && message.body == winners[message.id],
            ),
            isTrue,
          );
          final edits = await held.editSeqs(peer);
          expect(winners.keys.every((id) => edits[id] == 1000), isTrue);
          final replayable = await held.loadEventsSince(
            peer,
            author,
            0,
            limit: 1000,
          );
          expect(
            replayable.where(
              (event) =>
                  winners.containsKey(event.target) &&
                  event.body == winners[event.target],
            ),
            isEmpty,
          );
        } finally {
          await held.close();
        }
        result['cold_reopen_preserves_reflected_revisions'] = true;
        result['reflected_values_not_in_authored_replay'] = true;

        // Exercise the earlier routing regression too: A is online, but C
        // alone holds a newer edited value. A has no original rows for this
        // new wave, so it cannot satisfy B before C has answered. Use NEW IDs
        // so late phase-one packets cannot qualify the decrypted-response gate.
        winners.clear();
        selectedPrefix = 'echo-online-';
        final onlineAt = DateTime.now().subtract(const Duration(minutes: 2));
        for (var i = 0; i < 100; i++) {
          winners['echo-online-${i.toString().padLeft(3, '0')}'] =
              'online-updated-$i';
        }
        for (final device in [b, c]) {
          final storage = await open(device);
          final conversation = device == c ? identity : peer;
          try {
            var index = 0;
            for (final id in winners.keys) {
              await storage.appendMessage(
                Message(
                  id: id,
                  conversationId: conversation,
                  direction: device == c
                      ? MessageDirection.incoming
                      : MessageDirection.outgoing,
                  body: 'online-original-$index',
                  timestamp: onlineAt.add(Duration(milliseconds: index)),
                  status: MessageStatus.delivered,
                  author: device == c ? identity : author,
                  seq: 500 + index,
                  positionVerified: true,
                ),
              );
              await storage.editMessage(
                conversation,
                id,
                device == c ? winners[id]! : 'online-old-$index',
                seq: device == c ? 2000 : 1000,
              );
              index++;
            }
          } finally {
            await storage.close();
          }
        }
        final onlineLogOffset = await File(b.logPath).length();
        await a.start();
        await c.start();
        await base.join(c, a);
        await b.start();
        nudgedAt = null;
        Future<int> decryptedOnlineEchoes() async {
          final log = await File(b.logPath).open();
          try {
            await log.setPosition(onlineLogOffset);
            final text = utf8.decode(
              await log.read(await log.length() - onlineLogOffset),
              allowMalformed: true,
            );
            return RegExp(
              r'edit of own message (echo-online-\d{3}) handed',
            ).allMatches(text).map((match) => match.group(1)).toSet().length;
          } finally {
            await log.close();
          }
        }

        try {
          await waitUntil(
            () async {
              final now = DateTime.now();
              final nudge =
                  nudgedAt == null ||
                  now.difference(nudgedAt!) >= const Duration(seconds: 10);
              if (nudge) nudgedAt = now;
              final state = await inspect(reconcile: nudge);
              return state['count'] == 100 &&
                  await allBodies(b, peer) &&
                  await decryptedOnlineEchoes() > 0;
            },
            what:
                'B converges all 100 edits and decrypts C replies while A remains online',
            timeout: const Duration(minutes: 3),
          );
        } catch (_) {
          final messages = (await base.rows(
            b,
            peer,
          )).where((message) => winners.containsKey(message['id'])).toList();
          result['online_failure_history'] = {
            'count': messages.length,
            'matching_bodies': messages
                .where((message) => message['body'] == winners[message['id']])
                .length,
            'order_matches':
                jsonEncode(messages.map((message) => message['id']).toList()) ==
                jsonEncode(winners.keys.toList()),
            'direct_c_echoes': await decryptedOnlineEchoes(),
          };
          await cryptoSnapshot('failed-online-recovery', [a, b, c]);
          rethrow;
        }
        expect((await a.checked('/health'))['phase'], 'ready');
        expect(await allBodies(c, identity), isTrue);
        // A may mirror a recovered value before C sends its duplicate to B.
        // Require complete convergence plus positive plaintext delivery from
        // C at B, rather than requiring redundant copies of every value.
        result['b_decrypted_distinct_c_echoes_while_a_online'] =
            await decryptedOnlineEchoes();
        result['b_converged_100_edits_while_a_online'] = true;
        result['new_online_wave_ids_exclude_late_packets'] = true;
        await cryptoSnapshot('after-online-recovery', [a, b, c]);
        for (final device in [a, b, c]) {
          await device.stop();
        }

        // Controlled genuine evidence now becomes available at A. C stays
        // offline; own-device pages must upgrade the same edited values.
        final source = await open(a);
        try {
          var index = 0;
          for (final id in winners.keys) {
            // A may already hold the newer reflected body. Re-appending its
            // original post would reset that body under the retained edit
            // revision, creating a different conflict in the fixture itself.
            if (await source.loadMessageById(peer, id) == null) {
              await source.appendMessage(
                Message(
                  id: id,
                  conversationId: peer,
                  direction: MessageDirection.outgoing,
                  body: 'online-original-$index',
                  timestamp: onlineAt.add(Duration(milliseconds: index)),
                  status: MessageStatus.delivered,
                  author: author,
                  seq: 500 + index,
                  positionVerified: true,
                ),
              );
            }
            await source.editMessage(peer, id, winners[id]!, seq: 2000);
            index++;
          }
          final prepared = (await source.loadMessages(
            peer,
          )).where((message) => winners.containsKey(message.id)).toList();
          expect(prepared, hasLength(100));
          expect(
            prepared.every(
              (message) =>
                  !message.reflectedEdit && message.body == winners[message.id],
            ),
            isTrue,
            reason:
                'the controlled genuine source must be correct before it is started',
          );
        } finally {
          await source.close();
        }
        await a.start();
        await b.start();
        nudgedAt = null;
        await waitUntil(
          () async {
            final now = DateTime.now();
            final nudge =
                nudgedAt == null ||
                now.difference(nudgedAt!) >= const Duration(seconds: 10);
            if (nudge) nudgedAt = now;
            final state = await inspect(reconcile: nudge);
            return state['count'] == 100 &&
                state['reflectedEdits'] == 0 &&
                await allBodies(b, peer);
          },
          what:
              'A authentic history upgrades all B reflected edits while C is offline',
          timeout: const Duration(minutes: 3),
        );
        expect(await allBodies(a, peer), isTrue);
        await b.stop();
        await a.stop();
        held = await open(b);
        try {
          final messages = (await held.loadMessages(
            peer,
          )).where((message) => winners.containsKey(message.id)).toList();
          expect(
            messages.every(
              (message) =>
                  !message.reflectedEdit && message.body == winners[message.id],
            ),
            isTrue,
          );
        } finally {
          await held.close();
        }
        result['genuine_same_value_provenance_restored_without_c'] = true;
        result['logical_duplicates'] = 0;
        result['passed'] = true;
      } finally {
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }
    },
    skip: gate.skip,
  );
}
