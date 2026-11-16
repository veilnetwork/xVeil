import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/log.dart' show devLogDirectoryOverride;
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/peer_authorization_persistence.dart';
import 'package:xveil/state/ratchet_persistence.dart';

// A separate headless tester owns both real nodes and real stores. No node,
// wire transport, native conversation or application ACK is fabricated.
const messagesPerDirection = 3;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<void> _until(Future<bool> Function() ready, String stage) async {
  final watch = Stopwatch()..start();
  while (!await ready()) {
    if (watch.elapsed > const Duration(seconds: 75)) {
      throw TimeoutException(stage);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _Member {
  _Member(this.index, this.root, this.mode, this.lib, this.cold);
  final int index;
  final Directory root;
  final String mode;
  final DynamicLibrary lib;
  final bool cold;
  late final NodeId id;
  late final HiddenVolumeStorage storage;
  bool storageAssigned = false;
  EmbeddedNodeController? controller;
  FfiRatchetStateHandle? native;
  PeerAuthorizationPersistence? authorization;
  RatchetPersistence? persistence;
  VeilFlutterTransport? transport;
  MessagingService? messaging;
  int port = 0;
  int restored = 0;
  late List<Map<String, Object>> recoveredPositions;

  Future<void> open() async {
    final dir = '${root.path}/$index';
    if (!cold) {
      expect(const ManagedFsPlatform().createPrivateDirectory(dir), isTrue);
    }
    if (mode == 'hidden') {
      storage = HiddenVolumeStorage.async(
        workerSpaceOpener(
          '$dir/content.hv',
          paddingPreset: hv.PaddingPreset.none,
        ),
      );
    } else {
      final entry = ManagedIdentityEntry(
        id: ManagedIdentityId((index == 0 ? 'a' : 'b') * 32),
        protection: mode == 'encrypted'
            ? StorageProtection.encrypted
            : StorageProtection.unencrypted,
      );
      storage =
          (cold
                  ? ManagedIdentityStorage.existing(
                      profileDirectory: dir,
                      entry: entry,
                    )
                  : ManagedIdentityStorage.forCreation(
                      profileDirectory: dir,
                      entry: entry,
                    ))
              .storage;
    }
    storageAssigned = true;
    expect(
      await storage.open(
        password: mode == 'unencrypted' ? '' : 'synthetic native crash $index',
        createIfMissing: !cold,
      ),
      isTrue,
    );
    if (cold) {
      expect((await storage.loadProfile())?.displayName, 'fixture $index');
    } else {
      await storage.saveProfile(UserProfile(displayName: 'fixture $index'));
    }
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = listener.port;
    await listener.close();
    final identity = File(
      'test/native/fixtures/ratchet_state_identity_$index.toml',
    ).readAsStringSync();
    id = NodeId(
      blake3Hash(
        EmbeddedNode.signMessage(identity, Uint8List(0), lib: lib).publicKey,
      ),
    );
    final app = '$dir/a.sock';
    final admin = '$dir/n.sock';
    // Node runtime is deliberately fresh on every process start. Only the
    // selected identity's application storage carries ratchet state forward.
    for (final path in [app, admin]) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound) File(path).deleteSync();
    }
    final config = EmbeddedNode.composeConfig(
      identityToml: identity,
      listenTransport: 'tcp://127.0.0.1:$port',
      ipcSocket: app,
      adminSocket: admin,
      useBundledSeeds: false,
      meetingPoints: const [],
      serveDht: true,
      lib: lib,
    );
    controller = EmbeddedNodeController(
      appSocketPath: app,
      starter: () =>
          EmbeddedNode.startDeferred(admin, lib: lib)..applyConfig(config),
    );
    await controller!.start();
    expect(controller!.current.phase, NodePhase.connected);
    native = FfiRatchetStateHandle.connect(app, lib: lib);
    expect(native, isNotNull);
    authorization = PeerAuthorizationPersistence(
      native: native!,
      storage: storage,
    );
    authorization!.restore(await storage.loadPeerAuthorization());
    authorization!.start();
    persistence = RatchetPersistence(
      native: native!,
      storage: storage,
      peerAuthorization: authorization,
      coalesce: kRatchetFlushCoalesce,
    );
    final expectedRecovery = <Map<String, Object>>[];
    if (cold) {
      for (final entry in await loadStoredRatchetStates(storage)) {
        try {
          final marks = decodeRatchetReservations(
            await storage.getSetting(
              ratchetReservationKey(entry.conversationKey),
            ),
          );
          for (final at in native!.storedSendPositions(
            entry.conversationKey,
            entry.blob,
          )) {
            var next = at.next;
            for (final mark in marks) {
              if (_hex(mark.chain) == _hex(at.chain) && mark.next > next) {
                next = mark.next;
              }
            }
            expectedRecovery.add({
              'key': _hex(entry.conversationKey),
              'chain': _hex(at.chain),
              'next': next,
            });
          }
        } finally {
          entry.blob.fillRange(0, entry.blob.length, 0);
        }
      }
    }
    restored = await persistence!.restore();
    await persistence!.recoverReservedPositions();
    recoveredPositions = positions();
    if (cold) {
      expect(restored, greaterThan(0));
      expect(expectedRecovery, isNotEmpty);
      expect(recoveredPositions, unorderedEquals(expectedRecovery));
    }
    transport = await VeilFlutterTransport.connect(app);
    native!.bindPeerAuthorizationEvents(transport!.peerAuthorizationChanges);
    expect(await transport!.nodeId(), id);
    messaging = MessagingService(transport!, storage, anonymous: false)
      ..ratchet = persistence;
    messaging!.start();
  }

  List<Map<String, Object>> positions() => [
    for (final key in native!.list())
      for (final position in native!.sendPositions(key))
        {
          'key': _hex(key),
          'chain': _hex(position.chain),
          'next': position.next,
        },
  ];

  Future<String> invite() async {
    final invite = BootstrapInvite.parse(await transport!.createInvite());
    return BootstrapInvite(
      publicKey: invite.publicKey,
      nonce: invite.nonce,
      algo: invite.algo,
      transport: 'tcp://127.0.0.1:$port',
    ).toUri();
  }

  Future<void> close() async {
    Object? first;
    Future<void> release(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        first ??= error;
      }
    }

    await release(() async => messaging?.dispose());
    await release(() async => transport?.dispose());
    await release(() async => authorization?.close());
    await release(() => native?.close());
    await release(() async => controller?.stop());
    if (storageAssigned) await release(storage.close);
    if (port != 0) {
      await release(() async {
        final probe = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await probe.close();
      });
    }
    if (first != null) throw first!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native ratchet writer and cold continuation',
    () async {
      final supplied = Platform.environment['XVEIL_NATIVE_CRASH_ROOT'];
      if (supplied == null) throw StateError('missing isolated fixture');
      final root = Directory(supplied).resolveSymbolicLinksSync();
      final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
      expect(Directory(root).parent.path, temporary);
      expect(
        Directory(root).uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('xvrc-'),
      );
      final mode = Platform.environment['XVEIL_NATIVE_CRASH_MODE'];
      expect(['hidden', 'encrypted', 'unencrypted'], contains(mode));
      final cold = Platform.environment['XVEIL_NATIVE_CRASH_COLD'] == '1';
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final lib = DynamicLibrary.open(Platform.environment['VEIL_FFI_DYLIB']!);
      final oldLogDirectory = devLogDirectoryOverride;
      devLogDirectoryOverride = root;
      final members = [
        for (var i = 0; i < 2; i++)
          _Member(i, Directory(root), mode!, lib, cold),
      ];
      try {
        for (final member in members) {
          await member.open();
        }
        final old = cold
            ? jsonDecode(File('$root/ready').readAsStringSync()) as Map
            : null;
        if (old != null) {
          for (var i = 0; i < members.length; i++) {
            final before = old['members'][i] as Map;
            expect(before['id'], members[i].id.hex);
            final recovered = members[i].recoveredPositions;
            expect(recovered, isNotEmpty);
            for (final position in before['positions'] as List) {
              final matches = recovered.where(
                (p) =>
                    p['key'] == position['key'] &&
                    p['chain'] == position['chain'],
              );
              // Coalescing may retain an older root while RAM has already
              // rotated its DH chain. Every restored chain must obey its own
              // durable floor (checked before traffic above); a chain retained
              // from this live checkpoint must also pass its last used index.
              for (final match in matches) {
                expect(
                  match['next'],
                  greaterThanOrEqualTo(position['next'] as int),
                );
              }
            }
            final rows = await members[i].storage.loadMessages(
              members[1 - i].id.hex,
            );
            expect({for (final m in rows) m.id: m.body}, before['messages']);
          }
        }
        await members[1].transport!.joinInvite(await members[0].invite());
        await _until(() async {
          for (final m in members) {
            if (!(await m.transport!.peers()).any((p) => p.isActive)) {
              return false;
            }
          }
          return true;
        }, 'local TCP peering');
        if (!cold) {
          for (var i = 0; i < members.length; i++) {
            await members[i].storage.upsertContact(
              Contact(
                nodeId: members[1 - i].id,
                status: ContactStatus.accepted,
              ),
            );
          }
        }
        final phase = cold ? 'after' : 'before';
        for (var n = 0; n < messagesPerDirection; n++) {
          for (var i = 0; i < members.length; i++) {
            expect(
              await members[i].messaging!.sendText(
                members[1 - i].id,
                '$phase/$i/$n',
              ),
              isTrue,
            );
          }
        }
        await _until(() async {
          for (var i = 0; i < members.length; i++) {
            final rows = await members[i].storage.loadMessages(
              members[1 - i].id.hex,
            );
            final selected = rows
                .where((m) => m.body.startsWith('$phase/'))
                .toList();
            if (selected.length != 2 * messagesPerDirection) return false;
            if (selected
                .where((m) => m.direction == MessageDirection.outgoing)
                .any((m) => m.status != MessageStatus.delivered)) {
              return false;
            }
            for (final sender in [i, 1 - i]) {
              final direction = sender == i
                  ? MessageDirection.outgoing
                  : MessageDirection.incoming;
              expect(
                selected
                    .where((m) => m.direction == direction)
                    .map((m) => m.body),
                unorderedEquals([
                  for (var n = 0; n < messagesPerDirection; n++)
                    '$phase/$sender/$n',
                ]),
              );
            }
          }
          return true;
        }, 'exact bidirectional messages and peer ACKs');
        final proof = <String, Object?>{
          'pid': pid,
          'mode': mode,
          'members': [
            for (var i = 0; i < members.length; i++)
              {
                'id': members[i].id.hex,
                'positions': members[i].positions(),
                'messages': {
                  for (final m in await members[i].storage.loadMessages(
                    members[1 - i].id.hex,
                  ))
                    m.id: m.body,
                },
              },
          ],
        };
        for (final member in proof['members'] as List) {
          expect(member['positions'], isNotEmpty);
          expect(
            (member['messages'] as Map).length,
            2 * messagesPerDirection * (cold ? 2 : 1),
          );
        }
        // No saveAll, close or graceful shutdown before the parent's actual kill.
        final marker = '$root/${cold ? 'continued' : 'ready'}';
        File('$marker.tmp').writeAsStringSync(jsonEncode(proof));
        File('$marker.tmp').renameSync(marker);
        if (!cold) await Completer<void>().future;
      } finally {
        Object? closeError;
        for (final member in members.reversed) {
          try {
            await member.close();
          } catch (error) {
            closeError ??= error;
          }
        }
        devLogDirectoryOverride = oldLogDirectory;
        if (closeError != null) throw closeError;
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
