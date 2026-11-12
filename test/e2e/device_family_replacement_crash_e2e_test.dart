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
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/group_service.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'relay_cluster.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  for (final write in ['activation']) {
    for (final phase in ['before', 'after']) {
      test(
        'target family replacement survives SIGKILL $phase publication',
        () async {
          final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
          expect(evidence, isNotNull);
          expect(Platform.environment['XVEIL_E2E_STORAGE_TIMING'], isNot('1'));
          expect(
            ensureHiddenVolumeLoaded(dylibPath: gate.hiddenVolumeDylib),
            isTrue,
          );
          final fleet = await ProcessFleet.start(
            gate,
            labels: ['A', 'B', 'C', 'D'],
          );
          addTearDown(fleet.dispose);
          final a = fleet.a, b = fleet.b, c = fleet.devices['D']!;
          final previousSource = fleet.c;
          await base.linkProcesses(previousSource, b, owner: E2eIdentity.y);
          final prior = await b.checked('/devices');
          final previousGroup = prior['deviceGroup'] as String;
          final previousMembers =
              (prior['members'] as List)
                  .map((m) => (m as Map)['id'] as String)
                  .toList()
                ..sort();
          await previousSource.stop();
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
          final prepared = await a.checked(
            '/device_link_prepare',
            query: {
              'invite': DeviceLinkInvite(
                device: BootstrapInvite.parse(await base.physicalInvite(b)),
                document:
                    null, // Supported device-only invitation; no foreign document merge.
              ).toUri(),
            },
            body: E2eIdentity.x.phrase,
          );
          final tokenRaw = prepared['token'] as String;
          final token = DeviceLinkToken.parse(tokenRaw);
          expect(token.document, isNotEmpty);
          expect(token.source.hex, ai);
          final sourceDevices = await a.checked('/devices');
          final sourceMembers =
              (sourceDevices['members'] as List)
                  .map((member) => (member as Map)['id'] as String)
                  .toList()
                ..sort();
          expect(sourceMembers, contains(beforeB['nodeId']));
          await base.join(b, a);
          final adopted = await b.checked(
            '/device_adopt_prepare',
            body: tokenRaw,
          );
          if (adopted['restarting'] == true) await b.restart();
          await base.join(a, b);
          await base.join(b, a);
          expect((await b.checked('/devices'))['deviceGroup'], previousGroup);
          final nonce = 'replacement-$write-$phase';
          await File('${b.dir.path}/adoption-arm.json').writeAsString(
            jsonEncode({'nonce': nonce, 'write': write, 'phase': phase}),
          );
          final interrupted = a
              .call('/device_snapshot_send')
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
          await interrupted;
          await c.stop();
          await fleet.cluster.dispose(removeFiles: false);
          final cold = HiddenVolumeStorage.async(
            workerSpaceOpener('${b.dir.path}/store.hv'),
          );
          var coldSnapshotHistoryIncluded = false;
          var coldSnapshotContactIncluded = false;
          try {
            expect(await cold.open(password: 'e2e-B-password'), isTrue);
            final headerBytes = await cold.loadFile(
              'group:${token.groupId.hex}',
            );
            expect(headerBytes, isNotEmpty);
            final header = jsonDecode(utf8.decode(headerBytes!)) as Map;
            final manifest = SpaceManifest.fromJson(header['m']);
            expect(manifest?.groupId, token.groupId);
            expect(manifest?.isSovereignDevice, isTrue);
            final priorHeader =
                jsonDecode(
                      utf8.decode(
                        (await cold.loadFile('group:$previousGroup'))!,
                      ),
                    )
                    as Map;
            final priorManifest = SpaceManifest.fromJson(priorHeader['m'])!;
            expect(priorManifest.owner, isNot(manifest!.owner));
            final expectedBundle = base64Decode(
              (phase == 'after' ? header['s'] : priorHeader['s']) as String,
            );
            expect(expectedBundle, isNotEmpty);
            final gid = await cold.getSetting('devices.gid');
            final active = write == 'consumption' || phase == 'after';
            expect(gid, active ? token.groupId.hex : previousGroup);
            final pending = await cold.loadFile(
              GroupService.kPendingDeviceAdoptionFile,
            );
            final consumed = write == 'consumption' && phase == 'after';
            if (consumed) {
              expect(pending, isEmpty);
              expect(
                sha256.convert(pending!).toString(),
                marker!['proposedSha256'],
              );
            } else {
              expect(pending, isNotEmpty);
              expect(
                DeviceLinkToken.fromJson(
                  jsonDecode(utf8.decode(pending!)),
                )?.toJson(),
                token.toJson(),
              );
            }
            final credential = await readSovereignCredential(cold);
            expect(credential.corrupt, isFalse);
            {
              expect(
                credential.bundle,
                expectedBundle,
                reason:
                    'an active device group must retain its exact sovereign credential',
              );
              final signer = NativeSovereignGroupSigner.openBundle(
                credential.bundle!,
                active ? E2eIdentity.x.phrase : E2eIdentity.y.phrase,
              );
              try {
                expect(
                  signer.nodeId,
                  active ? manifest.owner : priorManifest.owner,
                );
              } finally {
                signer.close();
              }
            }
            var snapshotHasContact = false;
            for (final key in header['gs'] as List) {
              final segment = await cold.loadFile(key as String);
              expect(segment, isNotEmpty);
              coldSnapshotHistoryIncluded |= utf8
                  .decode(segment!)
                  .contains(history);
              for (final raw in jsonDecode(utf8.decode(segment)) as List) {
                final message = GroupMessage.fromJson(raw);
                final event = message == null
                    ? null
                    : DeviceSyncEvent.fromBody(message.body);
                snapshotHasContact |=
                    event?.kind == DeviceSyncKind.contactUp &&
                    event?.key == 's:$ci' &&
                    event?.payload['status'] == 'accepted';
              }
            }
            coldSnapshotContactIncluded = snapshotHasContact;
          } finally {
            await cold.close();
          }
          // The old node's private runtime must not supply an in-memory repair.
          await Directory('${b.dir.path}/runtime').delete(recursive: true);
          // No old relay cache, route or buffered source frame can repair boot.
          final fresh = await RelayCluster.start(
            veilCliPath: gate.veilCli!,
            root: Directory('${fleet.root.path}/fresh-relays'),
          );
          addTearDown(() async {
            await fresh.dispose(removeFiles: false);
            for (final relay in fresh.nodes) {
              await File(
                relay.logPath,
              ).copy('$evidence/fresh-$write-$phase-${relay.label}.log');
            }
          });
          for (final device in [a, b, c]) {
            device.peers
              ..clear()
              ..addAll(fresh.bootstrapPeers);
          }
          await b.start();
          final rebooted = await base.deviceInfo(b);
          expect(rebooted['nodeId'], beforeB['nodeId']);
          expect(rebooted['identity'], ai);
          final active = write == 'consumption' || phase == 'after';
          expect(
            (await b.checked('/devices'))['deviceGroup'],
            active ? token.groupId.hex : previousGroup,
          );
          final restoredMembers =
              ((await b.checked('/devices'))['members'] as List)
                  .map((m) => (m as Map)['id'] as String)
                  .toList()
                ..sort();
          expect(restoredMembers, active ? sourceMembers : previousMembers);
          if (active) {
            // All other clients are offline: replay uses B's stored snapshot.
            final coldDevices = await b.checked('/devices');
            final coldMembers =
                (coldDevices['members'] as List)
                    .map((member) => (member as Map)['id'] as String)
                    .toList()
                  ..sort();
            expect(coldMembers, sourceMembers);
            if (coldSnapshotContactIncluded) {
              await waitUntil(
                () async => await base.contactStatus(b, ci) == 'accepted',
                what:
                    'cold active group replays its saved contact decision without sources',
                describe: b.tail,
              );
            }
            if (coldSnapshotHistoryIncluded) await base.hasBody(b, ci, history);
          } else {
            expect(await base.contactStatus(b, ci), isNot('accepted'));
            expect(
              (await base.rows(b, ci)).any((m) => m['body'] == history),
              isFalse,
            );
          }
          await a.start();
          await c.start();
          await base.join(a, c);
          await base.join(c, a);
          expect(
            (await a.checked('/devices'))['deviceGroup'],
            prepared['deviceGroup'],
          );
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
            '$evidence/family-replacement-$phase-summary.json',
          ).writeAsString(
            jsonEncode({
              'write': write,
              'existingFamilyReplaced': true,
              'invitationIncludedDocument': false,
              'oldAndNewOwnersDiffer': true,
              'pointedCredentialOpensCorrectOwner': true,
              'pointedMemberSetMatchesExpected': true,
              'phase': phase,
              'realTargetVmSigkill': true,
              'coldEncryptedStateMatchesBoundary': true,
              'sourceOfflineDuringColdInspectionAndBoot': true,
              'allOtherClientsOfflineDuringColdBoot': true,
              'freshRelaysWithoutOldBufferedFrames': true,
              'groupPointerMatchesCrashBoundary': true,
              'physicalDeviceIdPreserved': true,
              'originalPreparedGroupAdopted': true,
              'sameTokenRetried': false,
              'activeGroupHasDurableCredential': true,
              'coldSnapshotContainsAcceptedContact':
                  coldSnapshotContactIncluded,
              'coldActiveGroupReplaysContact':
                  active && coldSnapshotContactIncluded,
              'coldActiveMemberSetChecked': active,
              'coldSnapshotHistoryIncluded': coldSnapshotHistoryIncluded,
              'coldHistoryAvailableForActiveGroup':
                  active && coldSnapshotHistoryIncluded,
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
