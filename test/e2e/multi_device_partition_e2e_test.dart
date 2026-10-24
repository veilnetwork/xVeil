@Timeout(Duration(minutes: 20))
library;

import 'package:flutter_test/flutter_test.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'cases 31/32: two live partitions converge without process restart',
    () async {
      final f = await ProcessFleet.start(
        gate,
        labels: const ['A', 'B', 'C', 'D'],
      );
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c, d = f.devices['D']!;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      await base.linkProcesses(c, d, owner: E2eIdentity.y);
      await base.join(b, d);
      await base.join(d, b);
      final infos = {
        for (final device in f.devices.values)
          device.label: await base.deviceInfo(device),
      };
      final x = infos['A']!['identity'] as String;
      final y = infos['C']!['identity'] as String;
      expect(infos['B']!['identity'], x);
      expect(infos['D']!['identity'], y);
      final pids = {
        for (final e in f.devices.entries)
          e.key: List<int>.of(e.value.ownedPids),
      };
      String peer(ProcessDevice device) => device == a || device == b ? y : x;
      Future<List<Map<String, dynamic>>> messages(ProcessDevice device) async =>
          (await base.rows(device, peer(device)))
              .where(
                (row) =>
                    (row['body'] as String? ?? '').startsWith('partition-'),
              )
              .toList();
      Future<void> send(ProcessDevice device, String text) async {
        await device.checked(
          '/send_message',
          query: {'peer': peer(device), 'text': text},
        );
      }

      for (final text in [
        'partition-edit-delete',
        'partition-reaction-target',
      ]) {
        await send(a, text);
        for (final device in f.devices.values) {
          await base.hasBody(device, peer(device), text);
        }
      }
      final initial = await messages(a);
      final editedId =
          initial.singleWhere(
                (row) => row['body'] == 'partition-edit-delete',
              )['id']
              as String;
      final reactionId =
          initial.singleWhere(
                (row) => row['body'] == 'partition-reaction-target',
              )['id']
              as String;
      Future<Map<String, dynamic>> reactions(ProcessDevice device) async {
        final response = await device.checked(
          '/reactions',
          query: {'peer': peer(device)},
        );
        final raw = Map<String, dynamic>.from(
          (response['reactions'] as Map)[reactionId] as Map? ?? {},
        );
        // Local self reactions intentionally use this installation's device
        // key; sibling application rebinds that key locally. Compare logical
        // identity state without collapsing duplicate reactor slots.
        final normalized = <String, dynamic>{};
        for (final entry in raw.entries) {
          final actor = entry.key == infos[device.label]!['nodeId']
              ? infos[device.label]!['identity'] as String
              : entry.key;
          expect(normalized.containsKey(actor), isFalse);
          normalized[actor] = entry.value;
        }
        return normalized;
      }

      await a.checked(
        '/react',
        query: {'peer': y, 'msg': reactionId, 'emoji': '👍'},
      );
      await waitUntil(() async {
        for (final device in f.devices.values) {
          if ((await reactions(device))[x] != '👍') return false;
        }
        return true;
      }, what: 'initial reaction reaches all four live processes');

      // Close every cross-half native session, including direct device links
      // and relay-to-relay paths. No process, cache or application state restarts.
      final admins = <String, Future<String> Function(List<String>)>{};
      final halves = <String, int>{};
      for (final device in f.devices.values) {
        final node = infos[device.label]!['nodeId'] as String;
        admins[node] = (command) => device.admin(gate.veilCli!, command);
        halves[node] = device == a || device == c ? 0 : 1;
      }
      for (var index = 0; index < f.cluster.nodes.length; index++) {
        final relay = f.cluster.nodes[index];
        admins[relay.nodeIdHex!] = (command) => f.cluster.admin(relay, command);
        halves[relay.nodeIdHex!] = index == 0 ? 0 : 1;
      }
      expect(admins, hasLength(7));
      Future<void> crossBans(bool ban) async {
        for (final entry in admins.entries) {
          for (final other in admins.keys) {
            if (halves[entry.key] != halves[other]) {
              await entry.value(['peers', ban ? 'ban' : 'unban', other]);
            }
          }
        }
      }

      Future<bool> isolated() async {
        for (final entry in admins.entries) {
          final text = await entry.value(['sessions', 'list', '--verbose']);
          final lines = text
              .split('\n')
              .where((line) => line.contains('\t'))
              .toList();
          expect(lines.first, startsWith('link_id\tnode_id\tsource\t'));
          for (final line in lines.skip(1)) {
            final fields = line.split('\t');
            expect(fields, hasLength(7));
            final remote = fields[1];
            if (!halves.containsKey(remote) ||
                halves[remote] != halves[entry.key]) {
              return false;
            }
          }
        }
        return true;
      }

      await crossBans(true);
      await waitUntil(
        isolated,
        what: 'all seven nodes have only same-half native sessions',
      );
      E2eLog.line('PROCESS_TWO_PARTITIONS_ZERO_CROSS_SESSIONS');

      await Future.wait([
        for (final device in f.devices.values)
          () async {
            for (var index = 0; index < 4; index++) {
              await send(device, 'partition-${device.label}-$index');
            }
          }(),
        a.checked(
          '/edit_message',
          query: {'id': editedId, 'text': 'partition-edited-on-A'},
        ),
        b.checked('/delete_message', query: {'id': editedId}),
        a.checked(
          '/react',
          query: {'peer': y, 'msg': reactionId, 'emoji': '🚀'},
        ),
        b.checked('/react', query: {'peer': y, 'msg': reactionId, 'emoji': ''}),
        d.checked(
          '/react',
          query: {'peer': x, 'msg': reactionId, 'emoji': '💡'},
        ),
      ]);
      for (final pair in [(a, c), (b, d), (c, a), (d, b)]) {
        for (var index = 0; index < 4; index++) {
          await base.hasBody(
            pair.$2,
            peer(pair.$2),
            'partition-${pair.$1.label}-$index',
          );
        }
      }
      expect(
        await isolated(),
        isTrue,
        reason: 'both halves exchange real messages without a cross path',
      );
      for (final device in [a, c]) {
        expect(
          (await messages(device)).where(
            (row) =>
                RegExp(r'^partition-[BD]-').hasMatch(row['body'] as String),
          ),
          isEmpty,
        );
      }
      for (final device in [b, d]) {
        expect(
          (await messages(device)).where(
            (row) =>
                RegExp(r'^partition-[AC]-').hasMatch(row['body'] as String),
          ),
          isEmpty,
        );
      }
      final read = <String, int>{};
      for (final device in f.devices.values) {
        read[device.label] =
            (await device.checked(
                  '/read_conv',
                  query: {'peer': peer(device)},
                ))['marker']
                as int;
        expect(read[device.label], greaterThan(0));
      }
      E2eLog.line('PROCESS_TWO_PARTITIONS_BOTH_HALVES_LIVE_16_MESSAGES');

      final healing = Stopwatch()..start();
      await crossBans(false);
      // Restore native connectivity after admin bans, not application journal
      // contents. The ordinary peer-up/history protocols must perform the merge.
      await base.join(a, b);
      await base.join(b, a);
      await base.join(c, d);
      await base.join(d, c);
      bool same(Object? expected, Object? actual) =>
          equals(expected).matches(actual, {});
      List<Object?> logical(List<Map<String, dynamic>> rows) => [
        for (final row in rows)
          [row['id'], row['direction'], row['body'], row['edited']],
      ];
      Future<bool> converged() async {
        final views = {
          for (final device in f.devices.values)
            device.label: await messages(device),
        };
        for (final device in f.devices.values) {
          final view = views[device.label]!;
          for (final sender in f.devices.keys) {
            if (!same(
              [
                for (var index = 0; index < 4; index++)
                  'partition-$sender-$index',
              ],
              [
                for (final row in view)
                  if ((row['body'] as String).startsWith('partition-$sender-'))
                    row['body'],
              ],
            )) {
              return false;
            }
            for (var index = 0; index < 4; index++) {
              if (view
                      .where((row) => row['body'] == 'partition-$sender-$index')
                      .length !=
                  1) {
                return false;
              }
            }
          }
          if (view.map((row) => row['id']).toSet().length != view.length) {
            return false;
          }
        }
        if (!same(logical(views['A']!), logical(views['B']!)) ||
            !same(logical(views['C']!), logical(views['D']!))) {
          return false;
        }
        if (views['A']!.any((row) => row['id'] == editedId)) return false;
        if (views['C']!.singleWhere((row) => row['id'] == editedId)['body'] !=
            'partition-edited-on-A') {
          return false;
        }
        final maps = [
          for (final device in f.devices.values) await reactions(device),
        ];
        if (maps.any((map) => !same(map, maps.first))) {
          return false;
        }
        if (maps.first[y] != '💡' || ![null, '🚀'].contains(maps.first[x])) {
          return false;
        }
        for (final pair in [(a, b), (c, d)]) {
          final expected = read[pair.$1.label]! > read[pair.$2.label]!
              ? read[pair.$1.label]!
              : read[pair.$2.label]!;
          final first =
              (await pair.$1.checked(
                    '/read_state',
                    query: {'conv': peer(pair.$1)},
                  ))['marker']
                  as int;
          final second =
              (await pair.$2.checked(
                    '/read_state',
                    query: {'conv': peer(pair.$2)},
                  ))['marker']
                  as int;
          if (first != second || first < expected) return false;
        }
        return true;
      }

      Stopwatch? stable;
      int? firstConvergedMs;
      await waitUntil(
        () async {
          if (!await converged()) {
            stable = null;
            return false;
          }
          firstConvergedMs ??= healing.elapsedMilliseconds;
          stable ??= Stopwatch()..start();
          return stable!.elapsed >= const Duration(seconds: 10);
        },
        what:
            'both identities converge after the live partition, including conflict/reaction/read state',
        describe: () async =>
            '${{
              for (final device in f.devices.values) device.label: {'rows': await messages(device), 'reactions': await reactions(device)},
            }}',
        timeout: const Duration(minutes: 4),
      );
      for (final device in f.devices.values) {
        expect(
          device.ownedPids,
          pids[device.label],
          reason: 'partition must preserve each process and its native caches',
        );
      }
      E2eLog.line(
        'PROCESS_TWO_PARTITIONS_HISTORY_CONFLICT_REACTION_READ_CONVERGENCE_PASS',
      );
      E2eLog.line(
        'PROCESS_TWO_PARTITIONS_METRICS '
        'firstConvergedMs=$firstConvergedMs '
        'stableMs=${stable!.elapsedMilliseconds} '
        'totalRecoveryMs=${healing.elapsedMilliseconds}',
      );
    },
    skip: gate.skip,
  );
}
