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
        final identity = aInfo['identity'] as String;
        final author = aInfo['nodeId'] as String;
        final peer = (await base.deviceInfo(c))['identity'] as String;
        await b.checked(
          '/send_message',
          query: {'peer': peer, 'text': 'echo-preflight'},
        );
        await base.hasBody(c, identity, 'echo-preflight');
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
        DateTime? nudgedAt;
        Future<Map<String, dynamic>> inspect({bool reconcile = false}) async {
          final token = ++nonce;
          final request = File('${b.dir.path}/storage-inspect.new');
          await request.writeAsString(
            jsonEncode({
              'nonce': token,
              'peer': peer,
              'prefix': 'echo-conflict-',
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
              messages.every(
                (message) => message['body'] == winners[message['id']],
              );
        }

        await c.start();
        await b.start();
        final started = DateTime.now();
        await waitUntil(
          () async {
            final now = DateTime.now();
            final nudge =
                nudgedAt == null ||
                now.difference(nudgedAt!) >= const Duration(seconds: 10);
            if (nudge) nudgedAt = now;
            final state = await inspect(reconcile: nudge);
            return state['count'] == 100 &&
                state['reflectedEdits'] == 100 &&
                await allBodies(b, peer);
          },
          what: 'B recovers all 100 conflicting edits solely from C',
          timeout: const Duration(minutes: 3),
        );
        result['recovery_seconds'] =
            DateTime.now().difference(started).inMilliseconds / 1000;
        result['a_offline_during_peer_recovery'] = true;
        result['full_hash_window_recovered'] = true;
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
        // A returns with genuine evidence of these same values. C stays offline;
        // own-device pages must upgrade provenance without changing the text.
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
