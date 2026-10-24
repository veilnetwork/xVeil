@Timeout(Duration(hours: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/debug/soak_hook.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/peer_authorization.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

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
              child: const DebugSoakHookHost(
                child: Directionality(
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
              if (request['reconcile'] == true) {
                await device!.messaging.reconcileOnConnect();
              }
              final peer = request['peer'] as String;
              final prefix = request['prefix'] as String;
              final messages = request['authorizationOnly'] == true
                  ? []
                  : (await device!.storage.loadMessages(peer))
                        .where((message) => message.id.startsWith(prefix))
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
              final response = File('${dir.path}/storage-inspected.new');
              await response.writeAsString(
                jsonEncode({
                  'nonce': request['nonce'],
                  if (authorization.isNotEmpty) 'authorization': authorization,
                  'count': messages.length,
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
        await tester.runAsync(() async => device?.stop());
      }
    },
    // testWidgets uses the binding's ten-minute default even with the library
    // annotation above. Long offline/backlog scenarios must keep their source
    // alive until the owning fleet explicitly stops it.
    timeout: const Timeout(Duration(hours: 4)),
    skip: label == null || !E2eGate.read().enabled,
  );
}
