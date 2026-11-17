@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';

void main() {
  test(
    'native metadata publication survives SIGKILL before and after its head',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final root = await Directory.systemTemp.createTemp('xveil-metadata-');
      final password = Uint8List.fromList([1, 2, 3]);
      Uint8List payload(int seed) {
        final random = Random(seed);
        return Uint8List.fromList(
          List.generate(49155, (_) => random.nextInt(256)),
        );
      }

      final before = payload(1);
      final after = payload(2);
      final seed = File('${root.path}/seed.hv');
      try {
        final space = hv.HvSpace.create(
          path: seed.path,
          password: password,
          argon: hv.ArgonPreset.min,
        );
        space.setPaddingPolicy(hv.PaddingPreset.none);
        final initial = HvKvLogStore(space);
        try {
          ManagedMetadataBlob(initial).write(before, initialize: true);
        } finally {
          initial.close();
        }
        for (final cut in [
          (boundary: 0, after: false),
          (boundary: 49, after: false),
          (boundary: 49, after: true),
        ]) {
          final fixture = await Directory(
            '${root.path}/case-${cut.boundary}-${cut.after}',
          ).create();
          await seed.copy('${fixture.path}/fixture.hv');
          final child = await Process.start(
            'python3',
            [
              '-c',
              'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
              'dart',
              '--packages=.dart_tool/package_config.json',
              'test/native/managed_metadata_blob_crash_writer.dart',
              fixture.path,
              '${cut.boundary}',
              cut.after ? 'after' : 'before',
            ],
            environment: {
              'TMPDIR': Platform.isMacOS
                  ? '/private/tmp/'
                  : Directory.systemTemp.path,
            },
          );
          final output = StringBuffer();
          final outDone = child.stdout
              .transform(utf8.decoder)
              .forEach(output.write);
          final errDone = child.stderr
              .transform(utf8.decoder)
              .forEach(output.write);
          int? status;
          final exit = child.exitCode.then((value) => status = value);
          try {
            final marker = File('${fixture.path}/ready');
            final watch = Stopwatch()..start();
            while (!await marker.exists()) {
              if (status != null) {
                fail('Writer stopped before its barrier: ${output.toString()}');
              }
              if (watch.elapsed > const Duration(seconds: 30)) {
                fail('Writer did not reach its barrier');
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(int.parse(await marker.readAsString()), child.pid);
            expect(child.kill(ProcessSignal.sigkill), isTrue);
            await exit;
            expect(status, -9);
          } finally {
            if (status == null) child.kill(ProcessSignal.sigkill);
            await exit;
            await Future.wait([outDone, errDone]);
          }
          final reopened = hv.HvSpace.open(
            path: '${fixture.path}/fixture.hv',
            password: password,
          )..cancelDeferredVacuum();
          reopened.setPaddingPolicy(hv.PaddingPreset.none);
          final store = HvKvLogStore(reopened);
          try {
            final blob = ManagedMetadataBlob(store);
            expect(blob.read(), cut.after ? after : before);
            blob.write(after);
            expect(blob.read(), after);
          } finally {
            store.close();
          }
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: Platform.isWindows ? 'POSIX SIGKILL qualification' : false,
  );
}
