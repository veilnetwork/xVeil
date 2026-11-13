@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/multi_identity_session.dart';

NodeId nodeId(int seed) => NodeId(Uint8List(32)..fillRange(0, 32, seed));

void main() {
  test(
    'a persisted mixed roster runs three native stores and reopens exact messages',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-mixed-storage-',
      );
      final profile = '${fixture.path}/profile';
      expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
      final path = '$profile/legacy.hv';
      final owned = <Storage>[];
      final keys = <Uint8List>[];
      MultiIdentitySession? session;
      HiddenVolumeStorage legacy() {
        final storage = HiddenVolumeStorage(
          hvSpaceOpener(path, argon: hv.ArgonPreset.min),
          keysOpener: hvKeysSpaceOpener(path),
        );
        owned.add(storage);
        return storage;
      }

      try {
        final rows = <RosterEntry>[];
        final child = legacy();
        expect(
          await child.open(
            password: 'synthetic hidden password',
            createIfMissing: true,
          ),
          isTrue,
        );
        await child.saveProfile(
          const UserProfile(displayName: 'Hidden fixture'),
        );
        final hiddenKeys = await child.exportSpaceKeys();
        keys.add(hiddenKeys);
        rows.add(RosterEntry(label: 'hidden', spaceKeys: hiddenKeys));
        await child.close();
        for (final protection in [
          StorageProtection.encrypted,
          StorageProtection.unencrypted,
        ]) {
          final entry = ManagedIdentityEntry(
            id: ManagedIdentityId(
              (protection == StorageProtection.encrypted ? 'a' : 'b') * 32,
            ),
            protection: protection,
          );
          final binding = ManagedIdentityStorage.forCreation(
            profileDirectory: profile,
            entry: entry,
          );
          owned.add(binding.storage);
          expect(
            await binding.storage.open(
              password: 'synthetic managed password',
              createIfMissing: true,
            ),
            isTrue,
          );
          await binding.storage.saveProfile(
            UserProfile(displayName: '${protection.name} fixture'),
          );
          final spaceKeys = await binding.storage.exportSpaceKeys();
          keys.add(spaceKeys);
          rows.add(
            RosterEntry(
              label: protection.name,
              spaceKeys: spaceKeys,
              storageLocator: entry.locator,
            ),
          );
          await binding.storage.close();
        }
        final master = legacy();
        expect(
          await master.open(
            password: 'synthetic master password',
            createIfMissing: true,
          ),
          isTrue,
        );
        await master.saveRoster(rows);
        await master.close();
        final coldMaster = legacy();
        expect(
          await coldMaster.open(password: 'synthetic master password'),
          isTrue,
        );
        final restored = await coldMaster.loadRoster();
        expect(restored, hasLength(3));
        expect(
          restored!.map((e) => e.storageLocator),
          rows.map((e) => e.storageLocator),
        );
        await coldMaster.close();

        final transports = <String, _Transport>{};
        session = MultiIdentitySession(
          WorkerMultiSpaceBacking(path, paddingPreset: hv.PaddingPreset.none),
          managedProfileDirectory: profile,
          runtimeDirBase: '${fixture.path}/unused-runtime',
          listenPortBase: 19000,
          boot: (spec, storage) async {
            final transport = _Transport(nodeId(spec.listenPort % 256));
            transports[spec.label] = transport;
            return IdentityNode(
              transport: transport,
              dispose: transport.dispose,
            );
          },
        );
        await session.bootAll(restored);
        expect(session.labels, ['hidden', 'encrypted', 'unencrypted']);
        expect(session.containerLockReleased, isFalse);
        final sender = nodeId(7);
        for (final row in restored) {
          final storage = session.storageFor(row.label)!;
          expect(await storage.exportSpaceKeys(), row.spaceKeys);
          await storage.upsertContact(
            Contact(nodeId: sender, status: ContactStatus.accepted),
          );
          final incoming = session.messagingFor(row.label)!.incoming.first;
          transports[row.label]!.deliver(
            sender,
            WireEnvelope.message(
              'for ${row.label}',
              id: 'fixture-${row.label}',
            ).encode(),
          );
          await incoming.timeout(const Duration(seconds: 15));
        }
        for (final row in restored) {
          final messages = await session
              .storageFor(row.label)!
              .loadMessages(sender.hex);
          expect(messages.map((message) => message.body), ['for ${row.label}']);
        }
        await session.disposeAll();
        expect(session.containerLockReleased, isTrue);
        expect(session.abandonedTeardowns, isEmpty);
        expect(session.labels, isEmpty);

        // Independent cold key-based opens prove exact data and actual release
        // of every native file owner. No network node or media engine was used.
        for (final row in restored) {
          final Storage storage;
          if (row.storageLocator case final ManagedStorageLocator locator) {
            storage = ManagedIdentityStorage.existing(
              profileDirectory: profile,
              entry: ManagedIdentityEntry.fromLocator(locator),
            ).storage;
            owned.add(storage);
          } else {
            storage = legacy();
          }
          expect(await storage.openWithKeys(row.spaceKeys), isTrue);
          expect(
            (await storage.loadMessages(
              sender.hex,
            )).map((message) => message.body),
            ['for ${row.label}'],
          );
          await storage.close();
        }
      } finally {
        await session?.disposeAll();
        for (final storage in owned) {
          await storage.close();
        }
        for (final key in keys) {
          key.fillRange(0, key.length, 0);
        }
        fixture.deleteSync(recursive: true);
      }
    },
  );
}

class _Transport implements VeilTransport {
  _Transport(this.me);
  final NodeId me;
  final inbound = StreamController<InboundMessage>.broadcast();
  void deliver(NodeId source, Uint8List bytes) => inbound.add(
    InboundMessage(
      src: source,
      payload: bytes,
      provenance: SenderProvenance.sessionPeer,
    ),
  );
  @override
  Future<NodeId> nodeId() async => me;
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() => inbound.close();
}
