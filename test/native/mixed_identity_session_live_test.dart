@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/log.dart' show devLogDirectoryOverride;
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/bundled_seeds.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/storage_router_providers.dart';

import '../support/retirement_secret_store.dart';

// Only the unused pre-session controller is inert. SessionBuilder,
// MultiIdentitySession's boot, every hosted stack/transport and storage are real.
class _NoSingleNode extends StaticNodeController {
  _NoSingleNode() : super(NodeStatus.stopped);
}

Future<void> _until(Future<bool> Function() ready, String stage) async {
  final watch = Stopwatch()..start();
  while (!await ready()) {
    if (watch.elapsed > const Duration(seconds: 60)) {
      throw TimeoutException(stage);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<int> _ports() async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final held = <RawDatagramSocket>[];
    try {
      final first = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        reuseAddress: false,
      );
      held.add(first);
      final base = first.port;
      if (base > 65531) continue;
      for (var i = 1; i <= 3; i++) {
        held.add(
          await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            base + i,
            reuseAddress: false,
          ),
        );
      }
      return base;
    } on SocketException {
      // Retry allocation only, never a failed node boot or storage open.
    } finally {
      for (final socket in held) {
        socket.close();
      }
    }
  }
  throw StateError('no free local three-node port range');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ordinary mixed all-online session keeps real native nodes across views',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final lib = DynamicLibrary.open(Platform.environment['VEIL_FFI_DYLIB']!);
      SharedPreferences.setMockInitialValues({'keep_all_online': true});
      final fixture = Directory.systemTemp.createTempSync('xvao-');
      final oldLog = devLogDirectoryOverride;
      devLogDirectoryOverride = fixture.path;
      final profile = '${fixture.path}/visible-storage';
      final legacy = '${fixture.path}/xveil.store';
      final runtime = '${fixture.path}/rt';
      expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
      final routers = <ProfileStorageRouter>[];
      final apps = <ProviderContainer>[];
      final keys = <Uint8List>[];
      final expectedIds = <String, NodeId>{};
      final expectedBodies = <String, Map<String, String>>{};
      final portRanges = <int>[];

      Future<ProfileStorageRouter> open() async {
        final router = await ProfileStorageRouter.open(
          profileDirectory: profile,
          legacyPath: legacy,
          legacyFactory: () => HiddenVolumeStorage(
            hvSpaceOpener(
              legacy,
              argon: hv.ArgonPreset.min,
              paddingPreset: hv.PaddingPreset.none,
            ),
            keysOpener: hvKeysSpaceOpener(legacy),
          ),
        );
        routers.add(router);
        return router;
      }

      Future<ProviderContainer> app(ProfileStorageRouter router) async {
        final base = await _ports();
        portRanges.add(base);
        final container = ProviderContainer(
          overrides: [
            profileStorageRouterProvider.overrideWithValue(router),
            singleSpaceStorageProvider.overrideWith((ref) {
              ref.watch(storageRouteRevisionProvider);
              return router.storage;
            }),
            nodeControllerProvider.overrideWithValue(_NoSingleNode()),
            quickUnlockSecretStoreProvider.overrideWithValue(
              RetirementSecretStore(),
            ),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: runtime,
                storePath: legacy,
                listenPort: base,
              ),
            ),
          ],
        );
        apps.add(container);
        await container.read(prefsProvider.future);
        return container;
      }

      Future<void> verifyNative(MultiIdentitySession session) async {
        expect(session.labels, ['hidden', 'encrypted', 'unencrypted']);
        for (final label in session.labels) {
          final stack = session.stackFor(label);
          expect(stack, isNotNull, reason: 'ordinary native boot for $label');
          expect(stack!.controller, isA<EmbeddedNodeController>());
          expect(stack.controller.current.phase, NodePhase.connected);
          expect(await stack.transport.nodeId(), expectedIds[label]);
          expect(stack.ratchetState, isNotNull);
          expect(session.messagingFor(label)!.ratchet, isNotNull);
          expect(await session.storageFor(label)!.getSetting('owner'), label);
        }
      }

      Future<void> peer(MultiIdentitySession session, int base) async {
        final labels = session.labels;
        for (var i = 0; i < labels.length; i++) {
          final invite = session.stackFor(labels[i])!.myInvite;
          final local = BootstrapInvite(
            publicKey: invite.publicKey,
            nonce: invite.nonce,
            algo: invite.algo,
            transport: 'quic://127.0.0.1:${base + i + 1}',
          );
          for (var j = i + 1; j < labels.length; j++) {
            await session.stackFor(labels[j])!.addContact(local);
          }
        }
        await _until(() async {
          for (final label in labels) {
            final peers = await session.stackFor(label)!.transport.peers();
            if (!labels
                .where((l) => l != label)
                .every(
                  (other) => peers.any(
                    (p) => p.isActive && p.nodeId == expectedIds[other],
                  ),
                )) {
              return false;
            }
          }
          return true;
        }, 'native local full mesh');
      }

      Future<void> exchange(MultiIdentitySession session, String phase) async {
        for (final from in session.labels) {
          for (final to in session.labels.where((label) => label != from)) {
            expect(
              await session
                  .messagingFor(from)!
                  .sendText(expectedIds[to]!, '$phase/$from/$to'),
              isTrue,
            );
          }
        }
        await _until(() async {
          for (final from in session.labels) {
            for (final to in session.labels.where((label) => label != from)) {
              final rows = await session
                  .storageFor(from)!
                  .loadMessages(expectedIds[to]!.hex);
              final outgoing = rows.where((m) => m.body == '$phase/$from/$to');
              if (outgoing.length != 1 ||
                  outgoing.single.status != MessageStatus.delivered) {
                return false;
              }
              if (rows
                      .where(
                        (m) =>
                            m.body == '$phase/$to/$from' &&
                            m.direction == MessageDirection.incoming,
                      )
                      .length !=
                  1) {
                return false;
              }
            }
          }
          return true;
        }, 'real messages and peer ACKs for $phase');
      }

      Future<void> released(int base) async {
        for (var i = 1; i <= 3; i++) {
          final socket = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            base + i,
            reuseAddress: false,
          );
          socket.close();
        }
      }

      try {
        var router = await open();
        final rows = <RosterEntry>[];
        for (var i = 0; i < StorageProtection.values.length; i++) {
          final mode = StorageProtection.values[i];
          await router.create(mode);
          expect(
            await router.storage.open(
              password: 'synthetic child $i',
              createIfMissing: true,
            ),
            isTrue,
          );
          await router.storage.saveProfile(UserProfile(displayName: mode.name));
          await router.storage.putSetting('owner', mode.name);
          final identity = File(
            'test/native/fixtures/ratchet_state_identity_$i.toml',
          ).readAsStringSync();
          await router.storage.saveNodeConfig(identity);
          expect(
            await setBundledSeedsAllowedInSpace(router.storage, false),
            isTrue,
          );
          expect(
            await setMeetingPointsInSpace(router.storage, const []),
            isTrue,
          );
          expectedIds[mode.name] = NodeId(
            blake3Hash(
              EmbeddedNode.signMessage(
                identity,
                Uint8List(0),
                lib: lib,
              ).publicKey,
            ),
          );
          final exported = await router.storage.exportSpaceKeys();
          keys.add(exported);
          rows.add(
            RosterEntry(
              label: mode.name,
              spaceKeys: exported,
              storageLocator: router.location,
            ),
          );
        }
        await router.create(StorageProtection.encrypted);
        expect(
          await router.storage.open(
            password: 'synthetic master',
            createIfMissing: true,
          ),
          isTrue,
        );
        await router.storage.saveRoster(rows);
        await router.rememberAccess();
        await router.storage.close();

        var container = await app(router);
        var controller = container.read(appControllerProvider.notifier);
        await controller.unlock('synthetic master');
        expect(container.read(appControllerProvider).phase, AppPhase.ready);
        final first = container.read(sessionProvider)!;
        await verifyNative(first);
        final originalStacks = {
          for (final label in first.labels) label: first.stackFor(label),
        };
        await peer(first, portRanges.last);
        for (final from in first.labels) {
          for (final to in first.labels.where((label) => label != from)) {
            await first
                .storageFor(from)!
                .upsertContact(
                  Contact(
                    nodeId: expectedIds[to]!,
                    status: ContactStatus.accepted,
                  ),
                );
          }
        }
        await exchange(first, 'before');
        for (final label in first.labels) {
          await controller.switchIdentity(label);
          expect(container.read(sessionProvider), same(first));
          expect(
            container.read(storageProvider),
            same(first.storageFor(label)),
          );
          await verifyNative(first);
          if (label != 'hidden') await controller.reclaimOwnedStorage();
          for (final member in first.labels) {
            expect(first.stackFor(member), same(originalStacks[member]));
          }
        }
        await exchange(first, 'after-maintenance');
        for (final from in first.labels) {
          expect(first.stackFor(from)!.ratchetState!.list(), isNotEmpty);
          for (final to in first.labels.where((label) => label != from)) {
            expectedBodies['$from/$to'] = {
              for (final m
                  in await first
                      .storageFor(from)!
                      .loadMessages(expectedIds[to]!.hex))
                m.id: m.body,
            };
            expect(expectedBodies['$from/$to'], hasLength(4));
          }
        }
        await controller.lock();
        expect(container.read(sessionProvider), isNull);
        expect(first.containerLockReleased, isTrue);
        expect(first.abandonedTeardowns, isEmpty);
        await released(portRanges.last);
        await router.close();
        container.dispose();
        apps.remove(container);

        router = await open();
        container = await app(router);
        controller = container.read(appControllerProvider.notifier);
        await controller.unlock('synthetic master');
        expect(container.read(appControllerProvider).phase, AppPhase.ready);
        final cold = container.read(sessionProvider)!;
        await verifyNative(cold);
        for (final from in cold.labels) {
          expect(
            cold.stackFor(from)!.ratchetState!.list(),
            isNotEmpty,
            reason: 'native restoration must precede a fresh connection',
          );
          for (final to in cold.labels.where((label) => label != from)) {
            expect({
              for (final m
                  in await cold
                      .storageFor(from)!
                      .loadMessages(expectedIds[to]!.hex))
                m.id: m.body,
            }, expectedBodies['$from/$to']);
          }
        }
        await peer(cold, portRanges.last);
        await exchange(cold, 'cold');
        for (final from in cold.labels) {
          for (final to in cold.labels.where((label) => label != from)) {
            expect(
              await cold.storageFor(from)!.loadMessages(expectedIds[to]!.hex),
              hasLength(6),
            );
          }
        }
        await controller.lock();
        expect(cold.containerLockReleased, isTrue);
        expect(cold.abandonedTeardowns, isEmpty);
        await released(portRanges.last);
      } finally {
        final cleanupErrors = <Object>[];
        for (final container in apps.reversed) {
          try {
            await container.read(appControllerProvider.notifier).lock();
          } catch (error) {
            cleanupErrors.add(error);
          }
          container.dispose();
        }
        for (final router in routers.reversed) {
          try {
            await router.close();
          } catch (error) {
            cleanupErrors.add(error);
          }
        }
        for (final key in keys) {
          key.fillRange(0, key.length, 0);
        }
        devLogDirectoryOverride = oldLog;
        if (cleanupErrors.isEmpty) fixture.deleteSync(recursive: true);
        expect(cleanupErrors, isEmpty);
      }
    },
    skip: Platform.environment['XVEIL_MIXED_NATIVE_LIVE'] == '1'
        ? false
        : 'set XVEIL_MIXED_NATIVE_LIVE=1 and both native libraries',
  );
}
