@Timeout(Duration(hours: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/debug/soak_hook.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/peer_authorization.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/device_sync_bridge.dart'
    show awaitDeviceHistoryRoom;
import 'package:xveil/state/data_import.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/device_sync_appliers.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';
import '../support/stand_cpu_profile.dart';
import '../support/stand_storage_timeline.dart';
import '../support/queued_snapshot_probe.dart';
import '../support/history_archive_fixture.dart';

// File-controlled synthetic stand probe, never an application HTTP endpoint.
// Populate the real durable Outbox while the master process is stopped, then
// ask the exact helper wired into history replay to observe that backlog.
Future<Map<String, Object>> _historyRoomProbe(
  E2eDevice device,
  String operation,
) async {
  final groups = device.groups!;
  final master = await groups.masterDeviceId();
  final registry = await groups.otherDeviceIds();
  final targets = await groups.addressableOwnDevices();
  final ready =
      master != null &&
      master != device.deviceNodeId &&
      targets.contains(master) &&
      !registry.contains(master);
  if (operation == 'info') {
    final state = await groups.deviceSyncState();
    return {
      'ready': ready,
      'masterKnown': master != null,
      'masterIsSelf': master == device.deviceNodeId,
      'masterInTargets': targets.contains(master),
      'masterInRegistry': registry.contains(master),
      'identityInRegistry': registry.contains(device.identityNodeId),
      'ownsGroup': await groups.ownsDeviceGroup(),
      'ownerAnnouncements': state.entries
          .where(
            (entry) =>
                entry.key.$1 == DeviceSyncKind.identityDoc &&
                entry.value.payload['o'] == true,
          )
          .length,
    };
  }
  if (operation != 'fill-and-check' || !ready) {
    throw StateError('history-room probe prerequisites not satisfied');
  }
  final groupId = (await groups.deviceGroupIdHex())!;
  final bundle = (await groups.load(NodeId.fromHex(groupId)))!;
  var snapshots = 0;
  while (device.messaging.pendingFramesFor(master) < 128 && snapshots < 128) {
    await device.messaging.sendGroupSnapshot(
      master,
      groupId,
      groups.snapshotJson(
        bundle,
        recipient: master,
        ownDevice: true,
        transferTag: 'room-stand-${snapshots++}',
      ),
      awaitInitialSend: false,
    );
  }
  final actualPending = device.messaging.pendingFramesFor(master);
  final aliasPending = device.messaging.pendingFramesFor(device.identityNodeId);
  final durablePending = (await device.storage.pendingOutboxFrames())
      .where((frame) => frame.peerHex == master.hex)
      .length;
  if (actualPending < 128 || durablePending < 128 || aliasPending >= 128) {
    throw StateError(
      'history-room queues do not distinguish the two addresses',
    );
  }
  final checked = Completer<void>();
  var cancelled = false, returned = false, sawActual = false, sawAlias = false;
  final waiting = awaitDeviceHistoryRoom(
    service: groups,
    pendingFramesFor: (peer) {
      sawActual |= peer == master;
      sawAlias |= peer == device.identityNodeId;
      if (!checked.isCompleted) checked.complete();
      return device.messaging.pendingFramesFor(peer);
    },
    cancelled: () => cancelled,
  ).then((_) => returned = true);
  // A sovereign registry may omit the authority owner entirely. The broken
  // loop then returns without checking even the identity alias.
  await Future.any<void>([checked.future, waiting.then<void>((_) {})]);
  await Future<void>(() {});
  final returnedBeforeCancel = returned;
  cancelled = true;
  await waiting;
  return {
    'ready': ready,
    'snapshotsQueued': snapshots,
    'actualPending': actualPending,
    'durableActualPending': durablePending,
    'aliasPending': aliasPending,
    'registryRecipients': registry.length,
    'sawActual': sawActual,
    'sawAlias': sawAlias,
    'returnedBeforeCancel': returnedBeforeCancel,
    'cancelledCleanly': returned,
  };
}

/// One native node per OS process, driven through the app's existing debug
/// API. Only the ready/unlock seam is supplied by the fixture. No identity
/// document cache or SharedPreferences instance is shared with another device.
void main() {
  final env = Platform.environment;
  final label = env['XVEIL_E2E_WORKER_LABEL'];
  testWidgets(
    'isolated device process worker',
    (tester) async {
      final gate = E2eGate.read();
      final dir = Directory(env['XVEIL_E2E_WORKER_DIR']!);
      final peers = (jsonDecode(env['XVEIL_E2E_WORKER_PEERS']!) as List)
          .map(
            (p) => BootstrapPeerCfg(
              transport: p['transport'] as String,
              publicKey: p['publicKey'] as String,
              nonce: p['nonce'] as String,
              algo: p['algo'] as String,
            ),
          )
          .toList();
      E2eDevice? device;
      StandCpuProfile? cpuProfile;
      StandStorageTimeline? storageTimeline;
      try {
        await tester.runAsync(() async {
          device = await E2eDevice.startWorker(
            gate: gate,
            label: label!,
            dir: dir,
            bootstrapPeers: peers,
            anonymous: env['XVEIL_E2E_ANONYMOUS'] == '1',
          );
          expect(
            device!.messaging.isAnonymousIdentity,
            env['XVEIL_E2E_ANONYMOUS'] == '1',
          );
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: device!.container,
              child: DebugSoakHookHost(
                port: int.parse(env['XVEIL_E2E_WORKER_HOOK_PORT']!),
                child: const Directionality(
                  textDirection: TextDirection.ltr,
                  child: SizedBox.shrink(),
                ),
              ),
            ),
          );
          while (!await File('${dir.path}/stop-worker').exists() &&
              !device!.rebootRequested) {
            // Private fixture control, never part of the application's API.
            // Read state through the live owner; parents must not open its
            // encrypted container while this worker holds the handle.
            final inspect = File('${dir.path}/storage-inspect.json');
            if (await inspect.exists()) {
              final request = jsonDecode(await inspect.readAsString()) as Map;
              await inspect.delete();
              if (request['replayFinishedOffer'] == true) {
                // A new authenticated transport copy of an old logical offer.
                // Only this private fixture can request it; no app debug API.
                final id = request['callId'] as String;
                final wire = WireEnvelope.callSignal(
                  CallSignal(
                    callId: id,
                    type: CallSignalType.offer,
                    posture: CallPosture.anonymous,
                    media: const CallMedia(audio: true),
                    mediaKey: generateCallMediaKeyContribution(),
                    sentAtMs: request['sentAtMs'] as int,
                    onBehalfOf: request['onBehalfOf'] as String,
                  ).encode(),
                ).withFrameId('fixture-replay:${request['nonce']}').encode();
                await device!.stack.transport.send(
                  NodeId.fromHex(request['peer'] as String),
                  wire,
                  anonymous: true,
                );
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(
                  jsonEncode({
                    'nonce': request['nonce'],
                    'sourceAccepted': true,
                  }),
                );
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (request['callDiagnostics'] == true) {
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(
                  jsonEncode({
                    'nonce': request['nonce'],
                    'diagnostics': diagnosticJournal.toJson(),
                  }),
                );
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (request['contactDecisions'] == true) {
                final records = await device!.storage.pendingContactDecisions();
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(
                  jsonEncode({
                    'nonce': request['nonce'],
                    'pending': records.length,
                  }),
                );
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (request['importContactArchive'] == true) {
                final appliers = device!.container.read(
                  deviceSyncAppliersProvider,
                );
                final before = appliers.failedApplies;
                final result = <String, Object?>{'nonce': request['nonce']};
                try {
                  final report =
                      await DataImporter(
                        storage: device!.storage,
                        appliers: appliers,
                        selfNodeIdHex: device!.container
                            .read(appControllerProvider)
                            .identity!
                            .nodeId
                            .hex,
                        localDeviceNodeIdHex: await device!.messaging
                            .savedSelfHex(),
                        groups: device!.groups,
                      ).run(
                        bytes: File(
                          '${dir.path}/contact-fixture.xva',
                        ).openRead(),
                      );
                  result.addAll({
                    'syncEvents': report.syncEvents,
                    'newFailedApplies': report.failedApplies - before,
                    'unconfirmedAppliers': report.unconfirmedAppliers,
                  });
                } on ImportRefused catch (error) {
                  result['refusal'] = error.reason.name;
                } catch (error) {
                  result['error'] = error.runtimeType.toString();
                }
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(jsonEncode(result));
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (request['conflictingMirrorTarget'] case final String target) {
                // A signed synthetic old-clock row, restricted to this test
                // worker's owned container; no production clock/debug API.
                final peer = request['peer'] as String;
                final message = (await device!.storage.loadMessageById(
                  peer,
                  target,
                ))!;
                final ttl = (await device!.storage.getContact(
                  NodeId.fromHex(peer),
                ))!.disappearingTtlSeconds!;
                final now = DateTime.now().millisecondsSinceEpoch;
                final staleTs =
                    message.timestamp.millisecondsSinceEpoch - ttl * 2000;
                final groups = device!.groups!;
                final gid = NodeId.fromHex((await groups.deviceGroupIdHex())!);
                final accepted = await groups.postDeviceEvent(
                  DeviceSyncEvent(
                    kind: DeviceSyncKind.msgMirror,
                    key: target,
                    tsMs: staleTs,
                    payload: {
                      'peer': peer,
                      'dir': message.direction.name,
                      'body': 'clock-conflict-stale-fixture',
                      if (message.author != null) 'au': message.author,
                      if (message.seq != null) 'sq': message.seq,
                    },
                  ),
                );
                await groups.compactStateLogs(gid);
                final bundle = (await groups.load(gid))!;
                final targetRows = bundle.messages.where((row) {
                  final event = DeviceSyncEvent.fromBody(row.body);
                  return event?.key == target && event?.payload['peer'] == peer;
                }).toList();
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(
                  jsonEncode({
                    'nonce': request['nonce'],
                    'accepted': accepted,
                    'canonicalWasLive':
                        now <
                        message.timestamp.millisecondsSinceEpoch + ttl * 1000,
                    'injectedClockWasExpired': staleTs + ttl * 1000 <= now,
                    'mirrors': targetRows
                        .where(
                          (row) =>
                              DeviceSyncEvent.fromBody(row.body)!.kind ==
                              DeviceSyncKind.msgMirror,
                        )
                        .length,
                    'edits': targetRows
                        .where(
                          (row) =>
                              DeviceSyncEvent.fromBody(row.body)!.kind ==
                              DeviceSyncKind.msgEdit,
                        )
                        .length,
                    'allRowsVerify':
                        targetRows.isNotEmpty &&
                        targetRows.every(
                          (row) => groups.debugMessageIsValid(gid, row),
                        ),
                    'staleBodies': targetRows
                        .where(
                          (row) =>
                              row.body.contains('clock-conflict-stale-fixture'),
                        )
                        .length,
                    'canonicalDeleted': await device!.storage.isMessageDeleted(
                      peer,
                      target,
                    ),
                    'scrubPending': bundle.deviceMessageScrubPending,
                  }),
                );
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (request['directEditTarget'] case final String target) {
                final peer = request['peer'] as String;
                final seq = request['seq'];
                final queued = await device!.storage.pendingOutboxFrames();
                final edits = [
                  for (final frame in queued)
                    if (frame.peerHex == peer) WireEnvelope.decode(frame.wire),
                ];
                final targets = edits
                    .where((e) => e.kind == WireKind.edit && e.id == target)
                    .toList();
                final sync = await device!.storage.conversationSync(peer);
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(
                  jsonEncode({
                    'nonce': request['nonce'],
                    'targetedEdits': targets.length,
                    'editSeq': targets.isEmpty ? null : targets.first.seq,
                    'voidSlots': edits
                        .where(
                          (e) =>
                              e.kind == WireKind.voidSeq &&
                              (seq == null || e.seq == seq),
                        )
                        .length,
                    'peerHighWater': sync.highWater[peer] ?? 0,
                    'cleanupPending': (await device!.storage.settingsKeys())
                        .contains('outbox.replacement_scrub_pending'),
                  }),
                );
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (request['outboxExpiryIds'] case final List values) {
                final groupId = (await device!.groups!.deviceGroupIdHex())!;
                if (request['queueFullSnapshot'] == true) {
                  final target = NodeId.fromHex(request['target'] as String);
                  final bundle = (await device!.groups!.load(
                    NodeId.fromHex(groupId),
                  ))!;
                  await device!.messaging.sendGroupSnapshot(
                    target,
                    groupId,
                    device!.groups!.snapshotJson(
                      bundle,
                      recipient: target,
                      ownDevice: true,
                    ),
                    awaitInitialSend: false,
                  );
                }
                final stats = queuedSnapshotStats(
                  await device!.storage.pendingOutboxFrames(),
                  groupId,
                  values.cast<String>().toSet(),
                  keepKey: request['keepKey'] as String,
                );
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(
                  jsonEncode({
                    'nonce': request['nonce'],
                    'groupId': groupId,
                    'cleanupPending': (await device!.storage.settingsKeys())
                        .contains('outbox.replacement_scrub_pending'),
                    ...stats,
                  }),
                );
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (request['historyRoom'] case final String operation) {
                final values = await device!.inZone(
                  () => _historyRoomProbe(device!, operation),
                );
                final response = File('${dir.path}/storage-inspected.new');
                await response.writeAsString(
                  jsonEncode({'nonce': request['nonce'], ...values}),
                );
                await response.rename('${dir.path}/storage-inspected.json');
                continue;
              }
              if (env['XVEIL_E2E_STORAGE_TIMELINE'] == label &&
                  request['storageTiming'] == true) {
                final evidence = env['XVEIL_E2E_EVIDENCE_DIR'];
                if (evidence == null) {
                  throw StateError('timeline needs private evidence');
                }
                storageTimeline ??= await StandStorageTimeline.open(
                  File('$evidence/storage-timeline-$label-$pid-private.jsonl'),
                );
                await storageTimeline!.capture();
              }
              if (env['XVEIL_E2E_CPU_PROFILE'] == '1' &&
                  request['storageTiming'] == true &&
                  (cpuProfile == null ||
                      request['resetStorageTiming'] == true)) {
                // Adoption restarts B's worker. Its first subsequent inspect
                // must start a new window even without another explicit reset.
                cpuProfile ??= StandCpuProfile();
                await cpuProfile!.reset();
              }
              if (request['reconcile'] == true) {
                await device!.messaging.reconcileOnConnect();
              }
              if (request['seedOwnHistory'] == true) {
                // Model history outside the bounded device journal. Write
                // through its live encrypted storage owner, without invoking
                // local-send taps or constructing any replicated group rows.
                final peer = request['peer'] as String;
                for (var i = 0; i < 3; i++) {
                  final id = 'record-stand-$i';
                  if (await device!.storage.loadMessageById(peer, id) != null) {
                    throw StateError('history fixture must be seeded once');
                  }
                  await device!.storage.appendMessage(
                    Message(
                      id: id,
                      conversationId: peer,
                      direction: MessageDirection.outgoing,
                      body: i == 1 ? '$id:${'x' * 160000}' : id,
                      timestamp: DateTime.utc(2020).add(Duration(seconds: i)),
                      status: MessageStatus.delivered,
                      author: device!.deviceNodeId.hex,
                      positionVerified: true,
                    ),
                  );
                }
              }
              Map<String, Object>? seededArchiveOrder;
              if (request['seedSharedHistory'] == true) {
                if (env['XVEIL_E2E_HISTORY_OVERLAP'] != '1') {
                  throw StateError('shared archive setup is not enabled');
                }
                final count = request['sharedRows'] as int;
                final seedBatchRows = count > 10000
                    ? preparedMessageBatchMaxRows
                    : 16;
                if (count < minHistoryArchiveRows ||
                    count > maxHistoryArchiveRows) {
                  throw StateError('invalid archive count');
                }
                final author = NodeId.fromHex(
                  request['sharedAuthor'] as String,
                );
                final peer = request['peer'] as String;
                final pending = <Message>[];
                Future<void> persistSeed() async {
                  final result = await device!.storage
                      .appendMissingMessageBatch(
                        pending,
                        beforeCommit: () async {},
                      );
                  if (result == null ||
                      result.length != pending.length ||
                      result.any(
                        (write) => write != PreparedMessageWrite.appended,
                      )) {
                    throw StateError(
                      'shared archive insertion was not complete',
                    );
                  }
                  pending.clear();
                }

                for (var i = 0; i < count; i++) {
                  final id = 'native-overlap-${i.toString().padLeft(4, '0')}';
                  if (await device!.storage.loadMessageById(peer, id) != null) {
                    throw StateError('shared archive must be seeded once');
                  }
                  pending.add(
                    Message(
                      id: id,
                      conversationId: peer,
                      direction: MessageDirection.outgoing,
                      body: '$id:archived payload',
                      timestamp: DateTime.utc(2020).add(Duration(seconds: i)),
                      status: MessageStatus.delivered,
                      author: author.hex,
                      seq: 100001 + i,
                      positionVerified: true,
                    ),
                  );
                  if (pending.length == seedBatchRows) await persistSeed();
                }
                if (pending.isNotEmpty) await persistSeed();
                seededArchiveOrder = historyArchiveOrderShape(
                  await device!.storage.loadMessageRows(peer),
                );
              }
              final peer = request['peer'] as String;
              final prefix = request['prefix'] as String;
              final bodyPrefix = request['bodyPrefix'] as String?;
              final List<Message> messages =
                  (request['authorizationOnly'] == true ||
                      request['historyProgressOnly'] == true)
                  ? []
                  : (await device!.storage.loadMessages(peer))
                        .where(
                          (message) =>
                              message.id.startsWith(prefix) &&
                              (bodyPrefix == null ||
                                  message.body.startsWith(bodyPrefix)),
                        )
                        .toList();
              final Object? authority = device!.stack.ratchetState;
              final authorization = <String, Object?>{};
              if (request['authorizationOnly'] == true) {
                authorization['storedPeers'] = [
                  for (final entry
                      in await device!.storage.loadPeerAuthorization())
                    entry.peer,
                ];
                if (authority is PeerAuthorizationStateHandle) {
                  authorization['nativePeers'] = [
                    for (final entry
                        in authority.exportPeerAuthorization().entries)
                      entry.peer,
                  ];
                }
                if (authority is PeerDeviceAuthorizationHandle) {
                  final identity = NodeId.fromHex(
                    request['identity'] as String,
                  );
                  final physical = NodeId.fromHex(
                    request['physical'] as String,
                  );
                  authorization['identityDeviceAllowed'] = authority
                      .peerDeviceProofAllowed(identity.bytes, physical.bytes);
                  authorization['physicalSelfAllowed'] = authority
                      .peerDeviceProofAllowed(physical.bytes, physical.bytes);
                }
              }
              Map<String, Object>? historyState;
              if (request['historyBodyPrefix'] case final String bodyPrefix) {
                final folded = await device!.groups!.deviceSyncState();
                final askingDevice = request['historyAskingDevice'] as String;
                final served = int.tryParse(
                  await device!.storage.getSetting(
                        'device.history.served.v1:$askingDevice',
                      ) ??
                      '',
                );
                historyState = {
                  'mirrors': folded.values
                      .where(
                        (event) =>
                            event.kind == DeviceSyncKind.msgMirror &&
                            event.payload['body'] is String &&
                            (event.payload['body'] as String).startsWith(
                              bodyPrefix,
                            ),
                      )
                      .length,
                  'servedRequests': served == null ? 0 : 1,
                };
              }
              final response = File('${dir.path}/storage-inspected.new');
              await response.writeAsString(
                jsonEncode({
                  'nonce': request['nonce'],
                  if (request['storageTiming'] == true)
                    'storageTiming': device!.messageApplyCensus(
                      reset: request['resetStorageTiming'] == true,
                    ),
                  if (authorization.isNotEmpty) 'authorization': authorization,
                  'historyState': ?historyState,
                  'seededArchiveOrder': ?seededArchiveOrder,
                  if (request['includeHistoryWire'] == true)
                    'historyWire': device!.privateHistoryWireSnapshot(),
                  if (request['includeHistoryWire'] == true ||
                      request['historyProgressOnly'] == true)
                    'historyGates': device!.privateHistoryGateSnapshot(),
                  if (request['includeHistoryWire'] == true ||
                      request['historyProgressOnly'] == true)
                    'historyFailures': errorJournal.entries
                        .where((e) => e.kind == 'device-history')
                        .length,
                  if (request['cursorDevices'] case final List devices)
                    'historyCursors': {
                      for (final id in devices)
                        id as String: await device!.storage.getSetting(
                          'device.history.cursor.v2:$id',
                        ),
                    },
                  if (request['historyProgressOnly'] == true)
                    'historyProgressOnly': true
                  else
                    'count': messages.length,
                  // One live-owner snapshot for crash/catch-up assertions;
                  // unlike the HTTP tail this cannot hide earlier duplicates.
                  if (request['includeRows'] == true)
                    'rows': [
                      for (final message in messages)
                        {
                          'id': message.id,
                          'body': message.body,
                          'status': message.status.name,
                          'orderAuthor': message.orderAuthor,
                          'orderSeq': message.orderSeq,
                        },
                    ],
                  if (request['includeIds'] == true)
                    'ids': [for (final message in messages) message.id],
                  // Private synthetic-stand evidence, never part of the app's
                  // diagnostic export or HTTP API. No message body is copied.
                  if (request['includePositions'] == true)
                    'positions': {
                      for (final message in messages)
                        message.id: {
                          'author': message.author,
                          'seq': message.seq,
                          'orderAuthor': message.orderAuthor,
                          'orderSeq': message.orderSeq,
                          'orderingOnly': message.ordering != null,
                          'verified': message.positionVerified,
                          'timestampMs':
                              message.timestamp.millisecondsSinceEpoch,
                        },
                    },
                  if (request['includeIds'] == true)
                    'statusCounts': {
                      for (final status in MessageStatus.values)
                        status.name: messages
                            .where((m) => m.status == status)
                            .length,
                    },
                  if (request['historyProgressOnly'] != true)
                    'reflectedEdits': messages
                        .where((message) => message.reflectedEdit)
                        .length,
                }),
              );
              await response.rename('${dir.path}/storage-inspected.json');
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      } finally {
        await tester.runAsync(() async {
          try {
            if (cpuProfile?.hasWindow == true) {
              final evidence = env['XVEIL_E2E_EVIDENCE_DIR'];
              if (evidence == null) {
                throw StateError('stand profiler needs a private evidence dir');
              }
              final snapshot = jsonEncode(await cpuProfile!.snapshot());
              // Adoption and crash probes restart the same label. Preserve
              // each boot's profile before updating the convenient latest view.
              await File(
                '$evidence/cpu-$label-$pid-private.json',
              ).writeAsString(snapshot);
              await File(
                '$evidence/cpu-$label-private.json',
              ).writeAsString(snapshot);
            }
          } finally {
            try {
              await storageTimeline?.close();
            } finally {
              cpuProfile?.close();
              try {
                await device?.stop();
              } finally {
                // Owned process-fixture evidence, not an application API.
                // Use the normal allowlisted report, including terminal events.
                final evidence = env['XVEIL_E2E_EVIDENCE_DIR'];
                if (env['XVEIL_E2E_DIAGNOSTICS'] == '1' && evidence != null) {
                  await Directory(evidence).create(recursive: true);
                  await File(
                    '$evidence/diagnostics-$label-$pid-private.json',
                  ).writeAsString(jsonEncode(diagnosticJournal.toJson()));
                }
              }
            }
          }
        });
      }
    },
    // testWidgets uses the binding's ten-minute default even with the library
    // annotation above. Long offline/backlog scenarios must keep their source
    // alive until the owning fleet explicitly stops it.
    timeout: const Timeout(Duration(hours: 4)),
    skip: label == null || !E2eGate.read().enabled,
  );
}
