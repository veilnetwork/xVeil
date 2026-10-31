import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/state/group_service.dart';

import '../support/timed_native_store.dart';

void main() {
  test(
    'worker journal reads batch metadata without skipping any durable payload',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'xv-segment-read-',
      );
      final library = DynamicLibrary.open(
        Platform.environment['VEIL_FFI_DYLIB']!,
      );
      final identity = File(
        Platform.environment['GROUP_SEGMENT_IDENTITY']!,
      ).readAsStringSync();
      final signed = EmbeddedNode.signMessage(
        identity,
        Uint8List(0),
        lib: library,
      );
      final signer = NativeGroupSigner(
        identityToml: identity,
        selfId: NodeId(blake3Hash(signed.publicKey)),
        selfPubKey: signed.publicKey,
        lib: library,
      );
      final inner = (await workerSpaceOpener('${directory.path}/fixture.hv')(
        password: Uint8List.fromList(utf8.encode('segment-read-fixture')),
        create: true,
      ))!;
      var recording = false;
      final counters = <String, int>{};
      final store = TimedNativeStore(inner, Stopwatch()..start(), (value) {
        if (recording) {
          final operation = value['operation'] as String;
          counters.update(operation, (n) => n + 1, ifAbsent: () => 1);
        }
      });
      final storage = HiddenVolumeStorage.fromAsyncStore(store);
      final service = GroupService(storage, signer);
      final samples = <Map<String, Object?>>[];
      try {
        for (final count in [128, 256]) {
          final gid = await service.createGroup('segment read fixture');
          final seed = (await service.load(gid))!;
          final rows = [
            for (var i = 0; i < count; i++)
              signer.signMessage(
                GroupMessage(
                  groupId: gid,
                  author: signer.selfId,
                  seq: i,
                  signature: Uint8List(0),
                  prevHash: '',
                  body: 'row-$i:${'x' * 4096}',
                  policyVersion: 1,
                  createdAtMs: seed.manifest.createdAtMs + i,
                ),
              ),
          ];
          expect(
            await service.ingestSnapshot(
              jsonEncode({
                'm': seed.manifest.toJson(),
                'c': [for (final c in seed.control) c.toJson()],
                'g': [for (final row in rows) row.toJson()],
                'r': [],
              }),
            ),
            isTrue,
          );
          final header =
              jsonDecode(
                    utf8.decode((await storage.loadFile('group:${gid.hex}'))!),
                  )
                  as Map;
          final segments = (header['gs'] as List).length;
          expect(segments, greaterThan(8));
          const repeats = 20;
          counters.clear();
          recording = true;
          final clock = Stopwatch()..start();
          for (var repeat = 0; repeat < repeats; repeat++) {
            final view = await service.load(gid);
            expect(view, isNotNull);
            expect(view!.messages.map((m) => m.body), rows.map((m) => m.body));
          }
          recording = false;
          samples.add({
            'rows': count,
            'segments': segments,
            'repeats': repeats,
            'rpc_counts': Map.of(counters),
            'us': clock.elapsedMicroseconds,
          });
          expect((await service.messagesOf(gid)).length, count);
        }
        final evidence = Platform.environment['GROUP_SEGMENT_BATCH_EVIDENCE'];
        if (evidence != null) {
          await File(evidence).writeAsString(
            jsonEncode({
              'samples': samples,
              'real_worker': true,
              'real_signatures': true,
            }),
          );
        }
        for (final sample in samples) {
          final counts = sample['rpc_counts'] as Map<String, int>;
          expect(counts['kv.commit'] ?? 0, 0);
          expect(
            counts['kv.get'] ?? 0,
            lessThan(
              (sample['segments'] as int) * 2 * (sample['repeats'] as int),
            ),
            reason:
                'metadata must not take two individual worker requests per segment',
          );
        }
      } finally {
        recording = false;
        await service.dispose();
        await storage.close();
        await directory.delete(recursive: true);
      }
    },
    skip:
        [
          'VEIL_FFI_DYLIB',
          'XVEIL_HV_DYLIB',
          'GROUP_SEGMENT_IDENTITY',
        ].every((key) => (Platform.environment[key]?.isNotEmpty ?? false))
        ? false
        : 'set verified native libraries and cached identity fixture',
  );
}
