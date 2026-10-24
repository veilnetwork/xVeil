@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/message_edit.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'isolated A/B/C: concurrent equal revisions converge through legacy frame IDs',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_CONCURRENT_EDITS_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'same_identity_devices': 2,
        'separate_processes': true,
        'local_network_only': true,
        'controlled_offline_edits': true,
        'legacy_frame_id_collisions': true,
        'production_fault_switch_added': false,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      try {
        await base.introduceProcesses(a, c);
        final group = await base.linkProcesses(a, b);
        final peer = (await base.deviceInfo(c))['identity'] as String;
        final identity = (await base.deviceInfo(a))['identity'] as String;
        await b.checked(
          '/send_message',
          query: {'peer': peer, 'text': 'conflict-preflight-B'},
        );
        await base.hasBody(c, identity, 'conflict-preflight-B');
        for (var i = 0; i < 2; i++) {
          await a.checked(
            '/send_message',
            query: {'peer': peer, 'text': 'conflict-original-$i'},
          );
          await base.hasBody(b, peer, 'conflict-original-$i');
          await base.hasBody(c, identity, 'conflict-original-$i');
        }
        final original = (await base.rows(a, peer))
            .where((m) => '${m['body']}'.startsWith('conflict-original-'))
            .toList();
        expect(original, hasLength(2));
        final ids = original.map((m) => m['id'] as String).toList();
        final values = ['concurrent-left', 'concurrent-right']
          ..sort(
            (x, y) => messageEditContentHash(
              x,
              const [],
            ).compareTo(messageEditContentHash(y, const [])),
          );
        final loser = values.first, winner = values.last;
        await c.stop();
        await b.stop();
        await a.stop();
        expect(
          ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
          isTrue,
        );
        for (final device in [a, b]) {
          final store = HiddenVolumeStorage.async(
            workerSpaceOpener('${device.dir.path}/store.hv'),
          );
          expect(
            await store.open(password: 'e2e-${device.label}-password'),
            isTrue,
          );
          try {
            for (var i = 0; i < ids.length; i++) {
              final body = (device == a) == (i == 0) ? winner : loser;
              await store.editMessage(peer, ids[i], body, seq: 1000);
              final fid = 'edit:${ids[i]}:1000';
              await store.enqueueOutboxFrame(
                fid,
                peer,
                WireEnvelope.edit(
                  ids[i],
                  body,
                  seq: 1000,
                ).withFrameId(fid).encode(),
              );
            }
          } finally {
            await store.close();
          }
        }
        result['conflicting_messages'] = ids.length;
        await c.start();
        await a.start();
        Future<bool> hasValues(
          ProcessDevice device,
          String conversation,
          List<String> expected,
        ) async {
          final rows = (await base.rows(
            device,
            conversation,
          )).where((m) => ids.contains(m['id'])).toList();
          return jsonEncode(rows.map((m) => m['id']).toList()) ==
                  jsonEncode(ids) &&
              jsonEncode(rows.map((m) => m['body']).toList()) ==
                  jsonEncode(expected);
        }

        await waitUntil(
          () => hasValues(c, identity, [winner, loser]),
          what:
              'C receives both A variants before B can send its colliding frame IDs',
          timeout: const Duration(minutes: 2),
        );
        result['both_arrival_orders_exercised'] = true;
        await b.start();
        await waitUntil(
          () async =>
              await hasValues(a, peer, [winner, winner]) &&
              await hasValues(b, peer, [winner, winner]) &&
              await hasValues(c, identity, [winner, winner]),
          what:
              'A/B and C select the same concurrent edit despite legacy frame collisions',
          timeout: const Duration(minutes: 3),
        );
        result['a_b_c_converged_at_equal_revision'] = true;
        result['same_id_order'] = true;
        result['duplicate_target_ids'] = 0;
        // A later losing value must not become the signed journal's winner,
        // or a restart/compaction would disagree with the message store.
        for (final id in ids) {
          for (final entry in [(a, winner), (b, loser)]) {
            await entry.$1.checked(
              '/device_post_event',
              query: {
                'kind': 'msgEdit',
                'key': id,
                'p': jsonEncode({'peer': peer, 'body': entry.$2, 'sq': 1000}),
              },
            );
          }
        }
        for (final device in [a, b]) {
          await device.checked(
            '/device_post_event',
            query: {
              'kind': 'settingSet',
              'key': 'conflict-head-${device.label}',
              'v': 'after-concurrent-edits',
            },
          );
        }
        Future<bool> journalMatches(ProcessDevice device) async {
          final events =
              (await device.checked('/device_events'))['events'] as Map;
          return ids.every((id) {
            final row = events['msgEdit|$id'];
            return row is Map && (row['payload'] as Map)['body'] == winner;
          });
        }

        await waitUntil(
          () async => await journalMatches(a) && await journalMatches(b),
          what:
              'both signed device journals keep the content winner before compaction',
        );
        // Live merges may already prune superseded rows. Keep B offline while
        // adding redundant local revisions, so the explicit compaction gate
        // measures a real prune instead of assuming a merge left work for it.
        await b.stop();
        for (final id in ids) {
          for (var repeat = 0; repeat < 2; repeat++) {
            await a.checked(
              '/device_post_event',
              query: {
                'kind': 'msgEdit',
                'key': id,
                'p': jsonEncode({'peer': peer, 'body': winner, 'sq': 1000}),
              },
            );
          }
        }
        await a.checked(
          '/device_post_event',
          query: {
            'kind': 'settingSet',
            'key': 'conflict-compaction-head',
            'v': 'after-redundant-edits',
          },
        );
        final compacted = await a.checked(
          '/group_compact',
          query: {'group': group},
        );
        final sizes = compacted['messages'] as List;
        expect(
          sizes[1] as int,
          lessThan(sizes[0] as int),
          reason: 'the compaction must actually discard rows',
        );
        expect(await journalMatches(a), isTrue);
        await b.start();
        await waitUntil(
          () => journalMatches(b),
          what: 'B receives the compacted winning edit state',
        );
        result['signed_journal_and_real_compaction_agree'] = true;
        for (final device in [a, b, c]) {
          await device.restart();
        }
        await waitUntil(
          () async =>
              await hasValues(a, peer, [winner, winner]) &&
              await hasValues(b, peer, [winner, winner]) &&
              await hasValues(c, identity, [winner, winner]),
          what: 'concurrent winner survives all three process restarts',
          timeout: const Duration(minutes: 2),
        );
        result['equal_revision_survives_all_restarts'] = true;
        await a.checked(
          '/edit_message',
          query: {'id': ids.first, 'text': 'later-serial-edit'},
        );
        await waitUntil(
          () async =>
              await hasValues(a, peer, ['later-serial-edit', winner]) &&
              await hasValues(b, peer, ['later-serial-edit', winner]) &&
              await hasValues(c, identity, ['later-serial-edit', winner]),
          what:
              'a later ordinary edit advances past the concurrent revision on all devices',
          timeout: const Duration(minutes: 3),
        );
        result['ordinary_edit_after_conflict_converged'] = true;
        for (final device in [a, b, c]) {
          await device.stop();
        }
        final revisions = <int>[];
        for (final device in [a, b, c]) {
          final store = HiddenVolumeStorage.async(
            workerSpaceOpener('${device.dir.path}/store.hv'),
          );
          expect(
            await store.open(password: 'e2e-${device.label}-password'),
            isTrue,
          );
          try {
            final conversation = device == c ? identity : peer;
            final edits = await store.editSeqs(conversation);
            revisions.add(edits[ids.first]!);
            expect(edits[ids.first], greaterThan(1000));
            expect(edits[ids.last], 1000);
            expect(
              (await store.loadMessageById(conversation, ids.first))!.body,
              'later-serial-edit',
            );
          } finally {
            await store.close();
          }
        }
        expect(revisions.toSet(), hasLength(1));
        result['same_edit_revision_in_reopened_containers'] = true;
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
