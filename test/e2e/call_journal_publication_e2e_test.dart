@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart'
    show deviceInfo, introduceProcesses, linkProcesses;

Future<void> writeThenKill(
  ProcessDevice target,
  Map<String, dynamic> entry,
) async {
  final marker = File('${target.dir.path}/call-write-committed');
  if (await marker.exists()) await marker.delete();
  final log = File('${target.dir.path}/call-crash-writer.log').openWrite();
  final process = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'flutter',
      'test',
      '--no-pub',
      '--reporter',
      'expanded',
      'test/e2e/call_journal_crash_writer_test.dart',
    ],
    environment: {
      'TMPDIR': '/private/tmp/',
      'XVEIL_CALL_CRASH_DIR': target.dir.path,
      'XVEIL_CALL_CRASH_ENTRY': jsonEncode(entry),
    },
  );
  target.ownedPids.add(process.pid);
  final stdoutDone = process.stdout.transform(utf8.decoder).forEach(log.write);
  final stderrDone = process.stderr.transform(utf8.decoder).forEach(log.write);
  int? status;
  final exited = process.exitCode.then((code) {
    status = code;
    return code;
  });
  try {
    final watch = Stopwatch()..start();
    while (!await marker.exists()) {
      if (status != null) {
        fail('the owned crash writer exited before its commit marker');
      }
      if (watch.elapsed > const Duration(seconds: 60)) {
        fail('the crash writer never committed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await marker.readAsString(), 'committed');
  } finally {
    if (status == null) await Process.run('kill', ['-KILL', '-${process.pid}']);
    await exited;
    await Future.wait([stdoutDone, stderrDone]);
    await log.close();
    final evidence = Platform.environment['XVEIL_CALL_PUBLICATION_EVIDENCE'];
    if (evidence != null) {
      await File(
        '${target.dir.path}/call-crash-writer.log',
      ).copy('$evidence/crash-writer-private.log');
    }
  }
}

void main() {
  final gate = E2eGate.read();
  test(
    'a post-commit crash must not lose the final call publication',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final evidence = Platform.environment['XVEIL_CALL_PUBLICATION_EVIDENCE'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final peer = (await deviceInfo(c))['identity'] as String;
      const id = 'post-commit-call-result';
      Future<Map<String, dynamic>?> row(ProcessDevice d) async {
        final entries = (await d.checked('/call_log'))['entries'] as List;
        final found = entries.where((e) => e['id'] == id).toList();
        expect(found.length, lessThanOrEqualTo(1));
        return found.singleOrNull == null
            ? null
            : Map<String, dynamic>.from(found.single as Map);
      }

      Future<Map<String, dynamic>?> folded(ProcessDevice d) async {
        final events = (await d.checked('/device_events'))['events'] as Map;
        final event = events['callLog|$id'] as Map?;
        return event == null
            ? null
            : Map<String, dynamic>.from(event['payload'] as Map);
      }

      await b.checked(
        '/call_log_add',
        query: {'id': id, 'peer': peer, 'outcome': 'completed', 'dur': '0'},
      );
      await waitUntil(
        () async => await row(a) != null && await folded(a) != null,
        what: 'A receives the freshly linked sibling call entry',
      );
      await b.checked(
        '/call_log_add',
        query: {'id': id, 'peer': peer, 'outcome': 'completed', 'dur': '1'},
      );
      await waitUntil(
        () async =>
            (await row(a))?['dur'] == 1 && (await folded(a))?['dur'] == 1,
        what: 'the online sibling publishes its own local call result',
        timeout: const Duration(seconds: 45),
      );
      final initial = (await row(a))!;
      await a.stop();
      await writeThenKill(a, {...initial, 'dur': 75});
      await a.start();
      var ar = await row(a), br = await row(b);
      var repaired = false;
      try {
        await waitUntil(
          () async {
            ar = await row(a);
            br = await row(b);
            return ar?['dur'] == 75 &&
                br?['dur'] == 75 &&
                (await folded(a))?['dur'] == 75 &&
                (await folded(b))?['dur'] == 75;
          },
          what:
              'the recovered local commit reaches B and both signed device journals',
          describe: () => 'A=${ar?['dur'] ?? 0} B=${br?['dur'] ?? 0}',
          timeout: const Duration(seconds: 45),
        );
        repaired = true;
      } finally {
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(
            jsonEncode({
              'devices': 3,
              'same_identity_devices': 2,
              'preexisting_shared_entry': true,
              'online_sibling_publication': true,
              'writer_killed_after_store_commit': true,
              'local_final_duration_seconds': ar?['dur'] ?? 0,
              'sibling_final_duration_seconds': br?['dur'] ?? 0,
              'recovered_publication': repaired,
              'duplicate_call_rows_observed': false,
              'production_fault_switch_added': false,
              'media_started': false,
            }),
          );
        }
      }
      final before = await folded(b);
      await a.stop();
      await a.start();
      await waitUntil(
        () async =>
            (await row(a))?['dur'] == 75 && (await row(b))?['dur'] == 75,
        what: 'the final call survives another ordinary restart',
      );
      expect(await folded(b), before);
    },
    skip: gate.skip,
  );
}
