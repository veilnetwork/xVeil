@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'fresh file offers retain delivery and sibling projection after TTL admission',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final a = fleet.a, b = fleet.b, c = fleet.c;
      final evidence = Platform.environment['XVEIL_MEDIA_OFFER_EVIDENCE'];
      final result = <String, Object?>{
        'devices': 3,
        'same_identity_devices': 2,
        'separate_processes': true,
        'local_network_only': true,
      };
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      try {
        await base.introduceProcesses(a, c);
        await base.linkProcesses(a, b);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        final ci = (await base.deviceInfo(c))['identity'] as String;
        final expected =
            <
              String,
              ({Uint8List bytes, ProcessDevice receiver, String sourcePath})
            >{};
        for (final leg in [
          (a, c, ci, ai, 'outbound'),
          (c, a, ai, ci, 'inbound'),
        ]) {
          final bytes = Uint8List.fromList(
            List.generate(32768, (i) => (i * 13 + leg.$5.length) & 255),
          );
          final path = '${leg.$1.dir.path}/offer-${leg.$5}.bin';
          await File(path).writeAsBytes(bytes);
          final sent = await leg.$1.checked(
            '/send_file',
            query: {
              'peer': leg.$3,
              'path': path,
              'name': 'offer-${leg.$5}.bin',
            },
          );
          final cid = sent['contentId'] as String;
          expected[cid] = (bytes: bytes, receiver: leg.$2, sourcePath: path);
          await waitUntil(
            () async =>
                (await leg.$2.checked(
                  '/has_file',
                  query: {'cid': cid},
                ))['hasFile'] ==
                true,
            what: 'fresh file completes on ${leg.$2.label}',
            timeout: const Duration(minutes: 3),
          );
          await waitUntil(() async {
            final receiver = (await base.rows(
              leg.$2,
              leg.$4,
            )).where((m) => m['fileContentId'] == cid).toList();
            final sibling = (await base.rows(
              b,
              ci,
            )).where((m) => m['fileContentId'] == cid).toList();
            return receiver.length == 1 && sibling.length == 1;
          }, what: 'fresh file has one receiver and sibling projection');
        }
        for (final device in [a, b, c]) {
          await device.stop();
        }
        expect(
          ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
          isTrue,
        );
        for (final device in [a, c]) {
          final storage = HiddenVolumeStorage.async(
            workerSpaceOpener('${device.dir.path}/store.hv'),
          );
          try {
            expect(
              await storage.open(password: 'e2e-${device.label}-password'),
              isTrue,
            );
            for (final entry in expected.entries) {
              final copy = entry.value;
              if (identical(copy.receiver, device)) {
                expect(
                  await storage.loadFile(entry.key),
                  copy.bytes,
                  reason: 'receiver cold container retains exact bytes',
                );
              } else {
                expect(
                  await File(copy.sourcePath).readAsBytes(),
                  copy.bytes,
                  reason: 'ordinary streaming sender keeps its source file',
                );
              }
              final conversation = device == a ? ci : ai;
              final rows = (await storage.loadMessages(conversation)).where(
                (m) => m.fileContentId == entry.key || m.fileId == entry.key,
              );
              expect(rows, hasLength(1), reason: 'cold metadata has one event');
            }
          } finally {
            await storage.close();
          }
        }
        result.addAll({
          'files': 2,
          'verified_cold_received_copies': 2,
          'verified_source_files': 2,
          'sibling_offer_copies': 2,
          'logical_duplicates': 0,
          'passed': true,
        });
      } finally {
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(jsonEncode(result));
        }
      }
    },
    skip: gate.skip,
  );
}
