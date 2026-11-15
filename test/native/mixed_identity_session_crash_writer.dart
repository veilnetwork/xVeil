import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/multi_identity_session.dart';

const messageCount = 12;
const masterPassword = 'synthetic mixed crash master';
NodeId fixtureNode(int seed) => NodeId(Uint8List(32)..fillRange(0, 32, seed));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'hold the mixed application session after observed ACKs',
    runFixture,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> runFixture() async {
  final supplied = Platform.environment['XVEIL_MIXED_CRASH_FIXTURE'];
  if (supplied == null) throw StateError('missing isolated fixture');
  final root = Directory(supplied).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!root.startsWith('$temporary/xveil-mixed-session-crash-')) exit(3);
  final profile = '$root/profile';
  if (!const ManagedFsPlatform().createPrivateDirectory(profile)) exit(4);
  final path = '$profile/legacy.hv';
  HiddenVolumeStorage hidden() => HiddenVolumeStorage(
    hvSpaceOpener(
      path,
      argon: hv.ArgonPreset.min,
      paddingPreset: hv.PaddingPreset.none,
    ),
    keysOpener: hvKeysSpaceOpener(path),
  );
  final rows = <RosterEntry>[];
  final first = hidden();
  if (!await first.open(
    password: 'synthetic hidden child',
    createIfMissing: true,
  )) {
    exit(5);
  }
  await first.saveProfile(const UserProfile(displayName: 'hidden'));
  rows.add(
    RosterEntry(label: 'hidden', spaceKeys: await first.exportSpaceKeys()),
  );
  await first.close();
  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    final entry = ManagedIdentityEntry(
      id: ManagedIdentityId(
        (mode == StorageProtection.encrypted ? 'a' : 'b') * 32,
      ),
      protection: mode,
    );
    final storage = ManagedIdentityStorage.forCreation(
      profileDirectory: profile,
      entry: entry,
    ).storage;
    if (!await storage.open(
      password: mode == StorageProtection.unencrypted
          ? ''
          : 'synthetic encrypted child',
      createIfMissing: true,
    )) {
      exit(6);
    }
    await storage.saveProfile(UserProfile(displayName: mode.name));
    rows.add(
      RosterEntry(
        label: mode.name,
        spaceKeys: await storage.exportSpaceKeys(),
        storageLocator: entry.locator,
      ),
    );
    await storage.close();
  }
  final master = hidden();
  if (!await master.open(password: masterPassword, createIfMissing: true)) {
    exit(7);
  }
  await master.saveRoster(rows);
  await master.close();

  final transports = <String, _Transport>{};
  final session = MultiIdentitySession(
    WorkerMultiSpaceBacking(path, paddingPreset: hv.PaddingPreset.none),
    managedProfileDirectory: profile,
    runtimeDirBase: '$root/unused-runtime',
    listenPortBase: 19000,
    boot: (spec, storage) async {
      final transport = _Transport(fixtureNode(spec.listenPort % 256));
      transports[spec.label] = transport;
      return IdentityNode(transport: transport, dispose: transport.dispose);
    },
  );
  await session.bootAll(rows);
  if (transports.length != 3) exit(8);
  final sender = fixtureNode(7);
  for (final row in rows) {
    await session
        .storageFor(row.label)!
        .upsertContact(Contact(nodeId: sender, status: ContactStatus.accepted));
  }
  // Reuse wire IDs across identities: a shared dedup/cache would lose data.
  // Queue every ingress before waiting for any ACK, without graceful shutdown.
  for (var i = 0; i < messageCount; i++) {
    for (final row in rows) {
      transports[row.label]!.deliver(
        sender,
        WireEnvelope.message('for ${row.label} $i', id: 'fixture-$i').encode(),
      );
    }
  }
  await Future.wait(
    transports.values.map((t) => t.acknowledged.future),
  ).timeout(const Duration(seconds: 40));
  File('$root/ready.pending')
    ..writeAsStringSync(
      jsonEncode({
        'pid': pid,
        'acks': {
          for (final t in transports.entries)
            t.key: t.value.seen.toList()..sort(),
        },
      }),
      flush: true,
    )
    ..renameSync('$root/ready');
  // Parent SIGKILLs this process group, including real storage workers. Do not
  // lock, dispose, read back messages or otherwise flush on the success path.
  await Completer<void>().future;
}

class _Transport implements VeilTransport {
  _Transport(this.me);
  final NodeId me;
  final inbound = StreamController<InboundMessage>.broadcast();
  final seen = <String>{};
  final acknowledged = Completer<void>();
  void deliver(NodeId sender, Uint8List bytes) => inbound.add(
    InboundMessage(
      src: sender,
      payload: bytes,
      replyId: 1,
      provenance: SenderProvenance.sessionPeer,
    ),
  );
  void observe(Uint8List bytes) {
    final frame = WireEnvelope.decode(bytes);
    if (frame.kind != WireKind.ack) return;
    if (frame.id == null ||
        !List.generate(messageCount, (i) => 'fixture-$i').contains(frame.id)) {
      throw StateError('unexpected fixture acknowledgement');
    }
    seen.add(frame.id!);
    if (seen.length == messageCount && !acknowledged.isCompleted) {
      acknowledged.complete();
    }
  }

  @override
  Future<NodeId> nodeId() async => me;
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async =>
      observe(payload);
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async => observe(payload);
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() => inbound.close();
}
