@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';
import 'package:xveil/domain/device_link.dart';
import 'package:xveil/state/group_service.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  for (final write in ['document', 'admission']) {
    for (final phase in ['before', 'after']) {
      test(
        'target adoption survives SIGKILL $phase $write store',
        () async {
          final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
          expect(evidence, isNotNull);
          expect(Platform.environment['XVEIL_E2E_STORAGE_TIMING'], isNot('1'));
          expect(
            ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
            isTrue,
          );
          final fleet = await ProcessFleet.start(gate);
          addTearDown(fleet.dispose);
          final a = fleet.a, b = fleet.b, c = fleet.c;
          await base.introduceProcesses(a, c);
          final ai = (await base.deviceInfo(a))['identity'] as String;
          final ci = (await base.deviceInfo(c))['identity'] as String;
          final beforeB = await base.deviceInfo(b);
          expect(beforeB['identity'], isNot(ai));
          const history = 'adoption-crash-preexisting-history';
          await a.checked(
            '/send_message',
            query: {'peer': ci, 'text': history},
          );
          await base.hasBody(c, ai, history);
          final historyId = (await base.rows(
            a,
            ci,
          )).singleWhere((m) => m['body'] == history)['id'];
          expect(historyId, isNotNull);
          expect(
            (await base.rows(b, ci)).any((m) => m['body'] == history),
            isFalse,
          );
          final invite = DeviceLinkInvite.parse(beforeB['invite'] as String);
          final prepared = await a.checked(
            '/device_link_prepare',
            query: {
              'invite': DeviceLinkInvite(
                device: BootstrapInvite.parse(await base.physicalInvite(b)),
                document: invite.document,
              ).toUri(),
            },
            body: E2eIdentity.x.phrase,
          );
          final tokenRaw = prepared['token'] as String;
          final token = DeviceLinkToken.parse(tokenRaw);
          expect(token.document, isNotEmpty);
          expect(token.source.hex, ai);
          await base.join(b, a);
          final nonce = 'adoption-$write-$phase';
          await File('${b.dir.path}/adoption-arm.json').writeAsString(
            jsonEncode({'nonce': nonce, 'write': write, 'phase': phase}),
          );
          final interrupted = b
              .call('/device_adopt_prepare', body: tokenRaw)
              .then<Object>(
                (value) => value,
                onError: (Object error) => 'interrupted',
              );
          Map<String, dynamic>? marker;
          await waitUntil(
            () async {
              final reached = File('${b.dir.path}/adoption-reached.json');
              if (!await reached.exists()) return false;
              marker =
                  jsonDecode(await reached.readAsString())
                      as Map<String, dynamic>;
              return marker!['nonce'] == nonce;
            },
            what: 'exact target adoption write boundary',
            describe: b.tail,
          );
          expect(marker!['write'], write);
          expect(marker!['phase'], phase);
          expect(marker!['storeReturned'], phase == 'after');
          final vm = marker!['processId'] as int;
          final group = await Process.run('ps', ['-p', '$vm', '-o', 'pgid=']);
          expect(int.parse('${group.stdout}'.trim()), b.ownedPids.last);
          await b.stop(crash: true);
          expect(b.lastExitCode, -ProcessSignal.sigkill.signalNumber);
          await interrupted;
          await waitUntil(
            () async {
              final result = await Process.run('ps', [
                '-p',
                '$vm',
                '-o',
                'state=',
              ]);
              final state = '${result.stdout}'.trim();
              return state.isEmpty || state.startsWith('Z');
            },
            what:
                'actual target VM has exited before cold container inspection',
          );
          await File('${b.dir.path}/adoption-arm.json').delete();
          // The source cannot repair the target during cold inspection/boot.
          await a.stop();
          final cold = HiddenVolumeStorage.async(
            workerSpaceOpener('${b.dir.path}/store.hv'),
          );
          try {
            expect(await cold.open(password: 'e2e-B-password'), isTrue);
            final document = await cold.loadFile(kSovereignIdentitySetting);
            final admission = await cold.loadFile(
              GroupService.kPendingDeviceAdoptionFile,
            );
            final legacy = await cold.getSetting(
              GroupService.kPendingDeviceAdoptionSetting,
            );
            final written = write == 'document' ? document : admission;
            final matches =
                written != null &&
                sha256.convert(written).toString() == marker!['proposedSha256'];
            expect(matches, phase == 'after');
            final consentStored = write == 'admission' && phase == 'after';
            if (consentStored) {
              final persisted = DeviceLinkToken.fromJson(
                jsonDecode(utf8.decode(admission!)),
              );
              expect(persisted?.toJson(), token.toJson());
            } else {
              expect(admission == null || admission.isEmpty, isTrue);
              expect(legacy == null || legacy.isEmpty, isTrue);
            }
            if (write == 'admission') expect(document, isNotEmpty);
          } finally {
            await cold.close();
          }
          // The old node's private runtime must not supply an in-memory repair.
          await Directory('${b.dir.path}/runtime').delete(recursive: true);
          await b.start();
          final rebooted = await base.deviceInfo(b);
          expect(rebooted['nodeId'], beforeB['nodeId']);
          if (write == 'document' && phase == 'before') {
            expect(rebooted['identity'], beforeB['identity']);
          } else {
            expect(rebooted['identity'], ai);
          }
          expect((await b.checked('/devices'))['deviceGroup'], isNull);
          await a.start();
          expect(
            (await a.checked('/devices'))['deviceGroup'],
            prepared['deviceGroup'],
          );
          await base.join(b, a);
          final needsRetry = write != 'admission' || phase != 'after';
          if (needsRetry) {
            // Neither the link token nor source-side membership is regenerated.
            final retry = await b.checked(
              '/device_adopt_prepare',
              body: tokenRaw,
            );
            if (retry['restarting'] == true) await b.restart();
          }
          await base.join(a, b);
          await base.join(b, a);
          await a.checked('/device_snapshot_send');
          await waitUntil(
            () async =>
                (await b.checked('/devices'))['deviceGroup'] ==
                prepared['deviceGroup'],
            what: 'target adopts the exact original prepared group',
            describe: b.tail,
          );
          final linked = await base.deviceInfo(b);
          expect(linked['identity'], ai);
          expect(linked['nodeId'], beforeB['nodeId']);
          await base.hasBody(b, ci, history);
          final outbound = 'adoption-$write-$phase-B-to-C';
          await b.checked(
            '/send_message',
            query: {'peer': ci, 'text': outbound},
          );
          await base.hasBody(c, ai, outbound);
          await base.hasBody(a, ci, outbound);
          final inbound = 'adoption-$write-$phase-C-to-family';
          await c.checked(
            '/send_message',
            query: {'peer': ai, 'text': inbound},
          );
          await base.hasBody(a, ci, inbound);
          await base.hasBody(b, ci, inbound);
          final aRows = await base.rows(a, ci);
          final bRows = await base.rows(b, ci);
          final cRows = await base.rows(c, ai);
          for (final body in [history, outbound, inbound]) {
            final sourceId = aRows.singleWhere((m) => m['body'] == body)['id'];
            expect(sourceId, isNotNull);
            expect(bRows.singleWhere((m) => m['body'] == body)['id'], sourceId);
            expect(cRows.singleWhere((m) => m['body'] == body)['id'], sourceId);
          }
          expect(
            bRows.singleWhere((m) => m['body'] == history)['id'],
            historyId,
          );
          List<Object?> order(List<Map<String, dynamic>> rows) => rows
              .where((m) => [history, outbound, inbound].contains(m['body']))
              .map((m) => m['id'])
              .toList();
          expect(order(aRows), hasLength(3));
          expect(order(bRows), order(aRows));
          expect(order(cRows), order(aRows));
          await File(
            '$evidence/adoption-$write-$phase-summary.json',
          ).writeAsString(
            jsonEncode({
              'write': write,
              'phase': phase,
              'realTargetVmSigkill': true,
              'coldEncryptedStateMatchesBoundary': true,
              'sourceOfflineDuringColdInspectionAndBoot': true,
              'noGroupMaterializedBeforeSnapshot': true,
              'physicalDeviceIdPreserved': true,
              'originalPreparedGroupAdopted': true,
              'sameTokenRetried': needsRetry,
              'newSourceTokenIssued': false,
              'historyExactlyOnce': true,
              'outboundDelivered': true,
              'inboundOnBothDevices': true,
              'messageIdsAndFinalOrderMatchAllThreeDevices': true,
            }),
          );
        },
        skip: !gate.enabled
            ? gate.skip
            : Platform.isWindows
            ? 'requires Unix process groups and SIGSTOP/SIGKILL'
            : Platform.environment['XVEIL_E2E_DEVICE_ADOPTION_CRASH'] != '1'
            ? 'set XVEIL_E2E_DEVICE_ADOPTION_CRASH=1'
            : false,
      );
    }
  }
}
