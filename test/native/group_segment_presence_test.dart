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

/// Isolate just the metadata batching: the control uses the former per-file
/// checks against the very same worker, journal and production ingest code.
class _PresenceStorage extends HiddenVolumeStorage {
  _PresenceStorage(super.store) : super.fromAsyncStore();
  bool individual = false;

  @override
  Future<List<bool>> hasFiles(List<String> ids) async => individual
      ? [for (final id in ids) await super.hasFile(id)]
      : super.hasFiles(ids);
}

void main() {
  test(
    'journal replays batch presence on a real worker without losing rows',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'xv-presence-rpc-',
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
        password: Uint8List.fromList(utf8.encode('presence-fixture')),
        create: true,
      ))!;
      bool recording = false;
      final counters = <String, int>{};
      final store = TimedNativeStore(inner, Stopwatch()..start(), (event) {
        if (!recording) return;
        final operation = event['operation'] as String;
        counters.update(operation, (n) => n + 1, ifAbsent: () => 1);
      });
      final storage = _PresenceStorage(store);
      final service = GroupService(storage, signer);
      final samples = <Map<String, Object?>>[];
      try {
        for (final count in [128, 512]) {
          final gid = await service.createGroup('presence fixture');
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
          final snapshot = jsonEncode({
            'm': seed.manifest.toJson(),
            'c': [for (final row in seed.control) row.toJson()],
            'g': [for (final row in rows) row.toJson()],
            'r': [],
          });
          expect(await service.ingestSnapshot(snapshot), isTrue);
          final header =
              jsonDecode(
                    utf8.decode((await storage.loadFile('group:${gid.hex}'))!),
                  )
                  as Map;
          final segments = (header['gs'] as List).cast<String>();
          if (count == 512) expect(segments.length, greaterThan(32));
          final phases = <Map<String, Object?>>[];
          const repeats = 5;
          for (final phase in ['A1', 'B', 'A2']) {
            storage.individual = phase != 'B';
            counters.clear();
            recording = true;
            final clock = Stopwatch()..start();
            for (var i = 0; i < repeats; i++) {
              expect(await service.ingestSnapshot(snapshot), isTrue);
            }
            clock.stop();
            recording = false;
            expect(
              (await service.load(gid))!.messages.map(groupMessageHash),
              rows.map(groupMessageHash),
            );
            expect((await service.messagesOf(gid)).length, count);
            phases.add({
              'phase': phase,
              'rpc_counts': Map.of(counters),
              'us': clock.elapsedMicroseconds,
            });
          }
          final a1 = phases[0]['rpc_counts'] as Map<String, int>;
          final b = phases[1]['rpc_counts'] as Map<String, int>;
          final a2 = phases[2]['rpc_counts'] as Map<String, int>;
          expect(a1, a2, reason: 'control metadata work must be reproducible');
          expect(
            (a1['kv.get'] ?? 0) - (b['kv.get'] ?? 0),
            2 * segments.length * repeats,
          );
          expect(
            (b['kv.getBatch'] ?? 0) - (a1['kv.getBatch'] ?? 0),
            2 * ((segments.length + 31) ~/ 32) * repeats,
          );
          expect(
            b['kv.commit'] ?? 0,
            0,
            reason:
                'an unchanged replay must remain durable without rewriting it',
          );

          // The presence result must not survive a call: repair a removed
          // segment from the full signed snapshot, even with a warm index.
          storage.individual = false;
          await storage.deleteStoredFile(segments.first);
          expect(await service.load(gid), isNull);
          expect(await service.ingestSnapshot(snapshot), isTrue);
          expect(
            (await service.load(gid))!.messages.map(groupMessageHash),
            rows.map(groupMessageHash),
          );
          samples.add({
            'rows': count,
            'segments': segments.length,
            'repeats': repeats,
            'phases': phases,
          });
        }
        final evidence = Platform.environment['GROUP_PRESENCE_EVIDENCE'];
        if (evidence != null) {
          await File(evidence).writeAsString(
            jsonEncode({
              'samples': samples,
              'real_worker': true,
              'real_signatures': true,
            }),
          );
        }
      } finally {
        recording = false;
        await service.dispose();
        await storage.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip:
        [
          'VEIL_FFI_DYLIB',
          'XVEIL_HV_DYLIB',
          'GROUP_SEGMENT_IDENTITY',
        ].every((key) => Platform.environment[key]?.isNotEmpty ?? false)
        ? false
        : 'set verified native libraries and cached identity fixture',
  );
}
