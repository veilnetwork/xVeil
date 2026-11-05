import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/clear_policy.dart';
import 'package:xveil/domain/contact_preferences.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/disappearing_messages.dart';
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/state/data_export.dart';
import 'package:xveil/state/data_import.dart';
import 'package:xveil/state/device_sync_appliers.dart';
import 'package:xveil/state/messaging.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
Future<HiddenVolumeStorage> storage(bool native) async {
  Directory? dir;
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), true);
    dir = await Directory.systemTemp.createTemp('xveil-policy-archive-');
    final path = '${dir.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: Uint8List.fromList(utf8.encode('fixture')),
        argon: hv.ArgonPreset.min,
      ),
    ).close();
    open = workerSpaceOpener(path);
  } else {
    final kv = FakeKvLogStore();
    open = ({required password, required bool create}) async =>
        SyncWrappedAsyncKvLogStore(kv);
  }
  final s = HiddenVolumeStorage.async(open);
  expect(await s.open(password: 'fixture', createIfMissing: true), true);
  addTearDown(() async {
    await s.close();
    await dir?.delete(recursive: true);
  });
  return s;
}

void main() {
  test('only the trusted local device id can admit a legacy archive', () async {
    final source = await storage(false), target = await storage(false);
    final bytes = BytesBuilder();
    await source.saveProfile(
      const UserProfile(displayName: 'archive-owner-fixture'),
    );
    await DataExporter(
      storage: source,
      nodeIdHex: id(1).hex,
      syncedSettingKeys: {},
    ).run(sink: (chunk) async => bytes.add(chunk), includeFiles: false);
    final encoded = bytes.takeBytes();
    final appliers = DeviceSyncAppliers()..register((_) {});
    for (final localDevice in [null, id(3).hex]) {
      await expectLater(
        DataImporter(
          storage: target,
          appliers: appliers,
          selfNodeIdHex: id(2).hex,
          localDeviceNodeIdHex: localDevice,
        ).run(bytes: Stream.value(encoded)),
        throwsA(
          isA<ImportRefused>().having(
            (e) => e.reason,
            'reason',
            ImportRefusal.otherIdentity,
          ),
        ),
      );
      expect(await target.loadProfile(), isNull);
    }
    await DataImporter(
      storage: target,
      appliers: appliers,
      selfNodeIdHex: id(2).hex,
      localDeviceNodeIdHex: id(1).hex,
    ).run(bytes: Stream.value(encoded));
    expect((await target.loadProfile())?.displayName, 'archive-owner-fixture');
  });
  for (final native in [false, true]) {
    for (final mode in ['active', 'off', 'older', 'default']) {
      test(
        'archive policy outranks only policy, not a newer alias native=$native mode=$mode',
        () async {
          final source = await storage(native),
              target = await storage(native),
              peer = id(2);
          final at = DateTime.now().millisecondsSinceEpoch - 100;
          await source.upsertContact(
            Contact(
              nodeId: peer,
              name: 'archive-old-alias',
              status: ContactStatus.accepted,
              disappearingTtlSeconds: mode == 'off' || mode == 'default'
                  ? null
                  : 60,
              disappearingSetAtMs: mode == 'default' ? 0 : at,
              disappearingSetBy: mode == 'default' ? '' : id(1).hex,
            ),
          );
          await target.upsertContact(
            Contact(
              nodeId: peer,
              name: 'live-new-alias',
              p2pOverride: ContactP2POverride.deny,
              disappearingTtlSeconds: mode == 'active' ? null : 120,
              disappearingSetAtMs: mode == 'older' ? at + 25 : at - 50,
              disappearingSetBy: id(1).hex,
            ),
          );
          await target.setContactStatus(peer, ContactStatus.blocked);
          final wire = LoopbackTransport(localNodeId: id(1));
          final service = MessagingService(wire, target);
          addTearDown(() async {
            await service.dispose();
            await wire.dispose();
          });
          final gate = DeviceSyncApplyGate(), appliers = DeviceSyncAppliers();
          void offer(DeviceSyncEvent e) => gate.offer(
            e,
            () => () async {
              if (e.key.startsWith('s:')) {
                await service.applyMirroredContactStatus(
                  peer,
                  ContactStatus.values.byName(e.payload['status']),
                  atMs: e.tsMs,
                );
              } else if (e.key.startsWith('d:')) {
                final policy = contactPolicyFromEvent(e);
                if (policy != null) {
                  await service.applyMirroredContactPolicy(peer, policy);
                }
              } else {
                await service.applyMirroredContact(
                  peer: peer,
                  name: e.payload['name'] as String?,
                  pinned: false,
                  archived: false,
                  allowPeerDelete: true,
                  clearPolicy: kDefaultClearRequestPolicy,
                  disappearing: DisappearingSetting.fromMirrorJson(e.payload),
                );
              }
            },
          );
          appliers.register(
            offer,
            settle: gate.settle,
            failures: () => gate.failedApplies,
          );
          offer(
            DeviceSyncEvent(
              kind: DeviceSyncKind.contactUp,
              key: peer.hex,
              tsMs: at + 50,
              payload: contactPrefsPayload((await target.getContact(peer))!),
            ),
          );
          await gate.settle();
          final bytes = BytesBuilder();
          await DataExporter(
            storage: source,
            nodeIdHex: id(1).hex,
            syncedSettingKeys: {},
          ).run(sink: (chunk) async => bytes.add(chunk), includeFiles: false);
          final encoded = bytes.takeBytes();
          final importer = DataImporter(
            storage: target,
            appliers: appliers,
            selfNodeIdHex: id(1).hex,
          );
          final report = await importer.run(bytes: Stream.value(encoded));
          expect(report.failedApplies, 0);
          expect(report.unconfirmedAppliers, 0);
          final c = (await target.getContact(peer))!;
          expect(c.name, 'live-new-alias');
          expect(c.status, ContactStatus.blocked);
          expect(c.p2pOverride, ContactP2POverride.deny);
          expect(
            c.disappearingTtlSeconds,
            mode == 'active'
                ? 60
                : mode == 'off'
                ? null
                : 120,
            reason: 'the archive must carry the independently clocked policy',
          );
          final repeated = await importer.run(bytes: Stream.value(encoded));
          expect(repeated.failedApplies, 0);
          expect(
            (await target.getContact(peer))!.disappearingTtlSeconds,
            c.disappearingTtlSeconds,
          );
          expect(
            await target.pendingContactPreferences(),
            isEmpty,
            reason: 'mirror does not echo publication',
          );
        },
      );
    }
  }
}
