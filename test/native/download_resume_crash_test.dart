@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

class _Offline extends LoopbackTransport {
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
}

HiddenVolumeStorage _storage(String dir) => HiddenVolumeStorage(
  hvSpaceOpener('$dir/store.hv', argon: hv.ArgonPreset.min),
);
List<String> _requested() =>
    List.generate(24, (i) => i.toRadixString(16).padLeft(64, '0'));

void main() {
  final workerDir = Platform.environment['XVEIL_DOWNLOAD_RESUME_CRASH_DIR'];
  if (workerDir != null) {
    test('owned writer waits after acknowledged download requests', () async {
      final resolved = await Directory(workerDir).resolveSymbolicLinks();
      final temporary = await Directory.systemTemp.resolveSymbolicLinks();
      expect(resolved.startsWith('$temporary/xveil-download-crash-'), true);
      expect(ensureHiddenVolumeLoaded(), true);
      final s = _storage(resolved);
      expect(await s.open(password: 'fixture', createIfMissing: true), true);
      final peer = NodeId(Uint8List(32)..fillRange(0, 32, 0xbb));
      await s.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final service = MessagingService(_Offline(), s, plainFileStream: true)
        ..start();
      for (final cid in _requested()) {
        expect(
          await service.downloadContent(peer, cid),
          ContentDownloadResult.requestedReoffer,
        );
      }
      await File(
        '$resolved/acknowledged',
      ).writeAsString('committed', flush: true);
      // No dispose/close: the parent kills this owned process group here.
      await Completer<void>().future;
    });
    return;
  }

  test(
    'acknowledged download intents survive an immediate process kill',
    () async {
      expect(ensureHiddenVolumeLoaded(), true);
      final dir = await Directory.systemTemp.createTemp(
        'xveil-download-crash-',
      );
      final evidence = Platform.environment['XVEIL_DOWNLOAD_RESUME_EVIDENCE'];
      try {
        final logFile = File('${dir.path}/writer.log');
        final log = logFile.openWrite();
        final child = await Process.start(
          'python3',
          [
            '-c',
            'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
            'flutter',
            'test',
            '--no-pub',
            '--reporter',
            'expanded',
            'test/native/download_resume_crash_test.dart',
          ],
          environment: {
            'TMPDIR': '/private/tmp/',
            'XVEIL_DOWNLOAD_RESUME_CRASH_DIR': dir.path,
          },
        );
        final stdoutDone = child.stdout
            .transform(utf8.decoder)
            .forEach(log.write);
        final stderrDone = child.stderr
            .transform(utf8.decoder)
            .forEach(log.write);
        int? status;
        final exit = child.exitCode.then((code) => status = code);
        try {
          final marker = File('${dir.path}/acknowledged');
          final watch = Stopwatch()..start();
          while (!await marker.exists()) {
            if (status != null) {
              fail('owned writer exited before acknowledgement');
            }
            if (watch.elapsed > const Duration(seconds: 60)) {
              fail('owned writer did not acknowledge the requests');
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(await marker.readAsString(), 'committed');
        } finally {
          // Kill the owned group even if its leader exited with a test error.
          // A descendant may still be unwinding after the leader is reaped.
          await Process.run('kill', ['-KILL', '-${child.pid}']);
          await exit;
          await Future.wait([stdoutDone, stderrDone]);
          await log.close();
          if (evidence != null) {
            await logFile.copy('$evidence/crash-writer-private.log');
          }
        }
        // The leader can be reaped before its descendants. A zombie is
        // already exited; wait for any still-live group member to exit too.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        var live = 0;
        do {
          final processes = await Process.run('ps', [
            '-axo',
            'pid=,pgid=,stat=',
          ]);
          live = (processes.stdout as String).split('\n').where((line) {
            final fields = line.trim().split(RegExp(r'\s+'));
            return fields.length >= 3 &&
                (int.tryParse(fields[0]) == child.pid ||
                    int.tryParse(fields[1]) == child.pid) &&
                !fields[2].startsWith('Z');
          }).length;
          if (live > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        } while (live > 0 && DateTime.now().isBefore(deadline));
        expect(live, 0, reason: 'owned child processes must have exited');
        final reopened = _storage(dir.path);
        final transport = _Offline();
        MessagingService? service;
        try {
          expect(await reopened.open(password: 'fixture'), true);
          service = MessagingService(
            transport,
            reopened,
            plainFileStream: true,
          );
          final recovered = await service.pendingAutoResumeContentIds();
          expect(recovered, unorderedEquals(_requested()));
          if (evidence != null) {
            await File('$evidence/crash-result.json').writeAsString(
              jsonEncode({
                'requests_acknowledged': 24,
                'recovered_requests': recovered.length,
                'writer_killed_without_shutdown': true,
                'owned_child_processes_exited': true,
                'network_used': false,
              }),
            );
          }
        } finally {
          await service?.dispose();
          await reopened.close();
          await transport.dispose();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['XVEIL_NATIVE_DOWNLOAD_RESUME'] != '1',
  );
}
