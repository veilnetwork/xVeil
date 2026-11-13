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
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_anchor_state.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';
import 'package:xveil/data/storage/managed_store_tag.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

final _id = ManagedIdentityId('1' * 32);
final _password = Uint8List.fromList([4, 5, 6]);
HvKvLogStore _open(String path, {bool create = false}) {
  final space = create
      ? hv.HvSpace.create(
          path: path,
          password: _password,
          argon: hv.ArgonPreset.min,
        )
      : (hv.HvSpace.open(path: path, password: _password)
          ..cancelDeferredVacuum());
  space.setPaddingPolicy(hv.PaddingPreset.none);
  return HvKvLogStore(space);
}

ManagedAnchorSnapshot _observe(HvKvLogStore content, ManagedAnchorState state) {
  final tag = ManagedStoreTag.read(
    content,
    identity: _id,
    role: ManagedStoreRole.content,
  );
  return state.resolve(
    contentIdentity: tag.identity,
    contentMarker: tag.generation!,
    innerSequence: content.commitSeq(),
    innerRoots: content.commitRoots(),
  );
}

Uint8List _body(int seed) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(1024, (_) => random.nextInt(256)));
}

void main() {
  test(
    'native repack keeps logical anchors across complete and killed publication',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final root = await Directory.systemTemp.createTemp(
        'xveil-managed-repack-',
      );
      try {
        late ManagedAnchorState initial;
        late ManagedAnchorSnapshot source;
        final seeded = _open('${root.path}/seed-content.hv', create: true);
        try {
          final floor = seeded.commit([
            ManagedStoreTag(
              identity: _id,
              role: ManagedStoreRole.content,
              generation: 'a' * 64,
            ).putOp(),
          ]);
          initial = ManagedAnchorState.initial(
            identity: _id,
            generation: ManagedGeneration(
              marker: 'a' * 64,
              innerFloor: floor,
              offset: 0,
            ),
          );
          for (var i = 0; i < 40; i++) {
            seeded.commit([AppendLogOp(Ns.fileChunks, i % 4 + 1, _body(i))]);
          }
          source = _observe(seeded, initial);
        } finally {
          seeded.close();
        }
        final seedMaintenance = _open(
          '${root.path}/seed-maintenance.hv',
          create: true,
        );
        try {
          seedMaintenance.commit([
            ManagedStoreTag(
              identity: _id,
              role: ManagedStoreRole.maintenance,
            ).putOp(),
          ]);
          ManagedMetadataBlob(
            seedMaintenance,
          ).write(initial.encode(), initialize: true);
        } finally {
          seedMaintenance.close();
        }

        for (final phase in ['complete', 'prepared', 'published']) {
          final fixture = await Directory('${root.path}/$phase').create();
          await File(
            '${root.path}/seed-content.hv',
          ).copy('${fixture.path}/content.hv');
          await File(
            '${root.path}/seed-maintenance.hv',
          ).copy('${fixture.path}/maintenance.hv');
          final child = await Process.start(
            'python3',
            [
              '-c',
              'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
              'dart',
              '--packages=.dart_tool/package_config.json',
              'test/native/managed_anchor_compaction_writer.dart',
              fixture.path,
              phase,
            ],
            environment: {'TMPDIR': '/private/tmp/'},
          );
          final output = StringBuffer();
          final stdoutDone = child.stdout
              .transform(utf8.decoder)
              .forEach(output.write);
          final stderrDone = child.stderr
              .transform(utf8.decoder)
              .forEach(output.write);
          int? status;
          final exit = child.exitCode.then((code) => status = code);
          try {
            final marker = File('${fixture.path}/ready');
            final watch = Stopwatch()..start();
            while (!await marker.exists()) {
              if (status != null) {
                fail('Compactor stopped before $phase: $output');
              }
              if (watch.elapsed > const Duration(seconds: 30)) {
                fail('Compactor did not reach $phase');
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(await marker.readAsString(), '${child.pid}:$phase');
            if (phase != 'complete') {
              expect(
                status,
                isNull,
                reason: 'writer must remain live at $phase',
              );
              expect(child.kill(ProcessSignal.sigkill), isTrue, reason: phase);
            }
            await exit.timeout(const Duration(seconds: 10));
            expect(status, phase == 'complete' ? 0 : -9);
          } finally {
            if (status == null) child.kill(ProcessSignal.sigkill);
            await exit.timeout(const Duration(seconds: 10));
            await Future.wait([stdoutDone, stderrDone]);
          }

          final maintenance = _open('${fixture.path}/maintenance.hv');
          try {
            ManagedStoreTag.read(
              maintenance,
              identity: _id,
              role: ManagedStoreRole.maintenance,
            );
            final blob = ManagedMetadataBlob(maintenance);
            var state = ManagedAnchorState.decode(blob.read());
            expect(state.prepared != null, phase != 'complete');
            final content = _open('${fixture.path}/content.hv');
            try {
              final observed = _observe(content, state);
              expect(
                observed.sequence,
                source.sequence + (phase == 'prepared' ? 0 : 1),
              );
              expect(
                observed.generation.marker,
                (phase == 'prepared' ? 'a' : 'b') * 64,
              );
              for (var i = 36; i < 40; i++) {
                expect(content.readLog(Ns.fileChunks, i % 4 + 1), _body(i));
              }
              expect(
                checkRollbackAnchor(
                  anchorSeq: source.sequence,
                  anchorRoot: source.roots[source.sequence],
                  currentSeq: observed.sequence,
                  history: observed.history,
                  roots: observed.roots,
                ).verdict,
                AnchorVerdict.clean,
              );
              if (state.prepared != null) {
                state = state.settle(observed);
                blob.write(state.encode());
              }
              content.commit([
                AppendLogOp(Ns.fileChunks, 9, Uint8List.fromList([99])),
              ]);
              expect(_observe(content, state).sequence, observed.sequence + 1);
            } finally {
              content.close();
            }
            final stable = ManagedAnchorState.decode(blob.read());
            expect(stable.prepared, isNull);
            final coldContent = _open('${fixture.path}/content.hv');
            try {
              final cold = _observe(coldContent, stable);
              expect(
                cold.sequence,
                source.sequence + (phase == 'prepared' ? 1 : 2),
              );
              expect(coldContent.readLog(Ns.fileChunks, 9), [99]);
              expect(
                checkRollbackAnchor(
                  anchorSeq: source.sequence,
                  anchorRoot: source.roots[source.sequence],
                  currentSeq: cold.sequence,
                  history: cold.history,
                  roots: cold.roots,
                ).verdict,
                AnchorVerdict.clean,
              );
            } finally {
              coldContent.close();
            }
          } finally {
            maintenance.close();
          }
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: Platform.isWindows ? 'POSIX SIGKILL qualification' : false,
  );
}
