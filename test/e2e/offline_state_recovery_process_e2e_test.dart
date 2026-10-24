@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/chat.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'isolated A/B/C: held edits and ACK recover without journal or C',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_STATE_RECOVERY_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'separate_processes': true,
        'same_identity_devices': 2,
        'local_network_only': true,
        'source_state_seeded_while_stopped': true,
        'delivery_ack_is_controlled_fixture': true,
        'production_fault_switch_added': false,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      try {
        await base.introduceProcesses(a, c);
        await base.linkProcesses(a, b);
        final peer = (await base.deviceInfo(c))['identity'] as String;
        await a.checked(
          '/send_message',
          query: {'peer': peer, 'text': 'state-original'},
        );
        await base.hasBody(b, peer, 'state-original');
        final first = (await base.rows(
          b,
          peer,
        )).singleWhere((m) => m['body'] == 'state-original');
        await c.stop();
        await a.checked(
          '/send_message',
          query: {'peer': peer, 'text': 'state-awaiting-ack'},
        );
        await base.hasBody(b, peer, 'state-awaiting-ack');
        final second = (await base.rows(
          b,
          peer,
        )).singleWhere((m) => m['body'] == 'state-awaiting-ack');
        expect(second['status'], isNot('delivered'));
        final firstId = first['id'] as String,
            secondId = second['id'] as String;
        final before = await base.rows(b, peer);
        final beforeIds = before.map((m) => m['id']).toList();
        await b.stop();
        await a.stop();

        // A controlled missing-journal fixture, entirely in test code. Both
        // workers are stopped before the parent opens A's real container. There
        // is no runtime storage hook, new product API or fake message applier.
        expect(
          ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
          isTrue,
        );
        final source = HiddenVolumeStorage.async(
          workerSpaceOpener('${a.dir.path}/store.hv'),
        );
        expect(await source.open(password: 'e2e-A-password'), isTrue);
        try {
          expect(
            await source.editMessage(
              peer,
              firstId,
              'state-offline-edit',
              seq: 1000,
            ),
            1000,
          );
          expect(
            await source.markMessageStatus(
              peer,
              secondId,
              MessageStatus.delivered,
            ),
            isTrue,
          );
        } finally {
          await source.close();
        }
        await a.start();
        final events = (await a.checked('/device_events'))['events'] as Map;
        expect(events.containsKey('msgEdit|$firstId'), isFalse);
        final status = events['msgStatus|$secondId'];
        expect(
          status is Map ? (status['payload'] as Map)['st'] : null,
          isNot('delivered'),
        );
        result['journal_lacks_recovered_edit_and_ack'] = true;
        result['c_offline_during_recovery'] = true;
        final recovering = Stopwatch()..start();
        await b.start();
        Future<bool> matches() async {
          final rows = await base.rows(b, peer);
          if (jsonEncode(rows.map((m) => m['id']).toList()) !=
              jsonEncode(beforeIds)) {
            return false;
          }
          final edited = rows.singleWhere((m) => m['id'] == firstId);
          final acked = rows.singleWhere((m) => m['id'] == secondId);
          return edited['body'] == 'state-offline-edit' &&
              edited['edited'] == true &&
              acked['status'] == 'delivered';
        }

        await waitUntil(
          matches,
          what:
              'held original and delivery status recover from A with C offline',
          timeout: const Duration(minutes: 3),
        );
        result['recovery_seconds'] = recovering.elapsedMilliseconds / 1000;
        result['same_logical_ids'] = true;
        result['edited_marker_restored'] = true;
        result['delivered_restored'] = true;
        result['logical_duplicates'] = 0;
        await a.stop();
        await b.restart();
        expect(await matches(), isTrue);
        result['retained_after_restart_without_other_devices'] = true;
        await b.stop();
        final recovered = HiddenVolumeStorage.async(
          workerSpaceOpener('${b.dir.path}/store.hv'),
        );
        expect(await recovered.open(password: 'e2e-B-password'), isTrue);
        try {
          expect((await recovered.editSeqs(peer))[firstId], 1000);
          expect(
            (await recovered.loadMessageById(peer, secondId))!.status,
            MessageStatus.delivered,
          );
          result['edit_frontier_restored_in_reopened_container'] = true;
        } finally {
          await recovered.close();
        }
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
