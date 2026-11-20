// Real embedded node + native FFI; the blocked-wait oracle lives in the SDK.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';

import '../e2e/e2e_env.dart' show waitUntil;

void main() {
  final library = Platform.environment['VEIL_FFI_DYLIB'];
  for (final tcp in [false, true]) {
    test(
      'network dispatch is received before temporary client close tcp=$tcp',
      () async {
        final lib = DynamicLibrary.open(library!);
        final root = await Directory.systemTemp.createTemp(
          'xveil-network-dispatch-',
        );
        final plan = localEndpointPlanFor(
          tcp ? 'windows' : 'linux',
          runtimeDir: root.path,
        );
        expect(plan.loopbackTcp, tcp);
        final log = File('${root.path}/node-private.log');
        final identity = await File(
          'test/native/fixtures/ratchet_state_identity_0.toml',
        ).readAsString();
        final config = EmbeddedNode.composeConfig(
          identityToml: identity,
          listenTransport: 'quic://127.0.0.1:0',
          ipcSocket: plan.ipcEndpoint(root.path),
          adminSocket: plan.adminEndpoint(root.path),
          useBundledSeeds: false,
          meetingPoints: const [],
          logFile: log.path,
          lib: lib,
        );
        expect(config, matches(RegExp(r'meeting_points\s*=\s*"off"')));
        expect(config, matches(RegExp(r'builtin_seed_policy\s*=\s*"never"')));
        final configFile = File('${root.path}/node.toml');
        await configFile.writeAsString(config);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['700', root.path]);
          await Process.run('chmod', ['600', configFile.path]);
        }
        final ports = <int>[];
        final controller = EmbeddedNodeController(
          configPath: configFile.path,
          appSocketPath: plan.ipcSocket(root.path),
          lib: lib,
        );
        var received = 0;
        try {
          await controller.start();
          expect(controller.current.phase, NodePhase.connected);
          if (tcp) {
            for (final name in ['admin.port', 'ipc.port']) {
              ports.add(
                int.parse(
                  (await File('${root.path}/$name').readAsString()).trim(),
                ),
              );
            }
          }
          final expected = <(veil.NetworkKind, String)>[
            (veil.NetworkKind.wifi, 'Wifi'),
            // Different default networks can have the same attachment kind.
            // Each explicit notification must reach the daemon before close.
            (veil.NetworkKind.wifi, 'Wifi'),
            (veil.NetworkKind.cellular, 'Cellular'),
            (veil.NetworkKind.cellular, 'Cellular'),
            (veil.NetworkKind.offline, 'Offline'),
            (veil.NetworkKind.ethernet, 'Ethernet'),
            (veil.NetworkKind.unknown, 'Unknown'),
          ];
          for (var i = 0; i < expected.length; i++) {
            final client = await veil.VeilClient.connect(
              plan.ipcSocket(root.path),
            );
            final sub = client.events().listen((_) {});
            try {
              expect(await client.nodeId(), hasLength(32));
              await client.notifyNetworkChanged(
                expected[i].$1,
                mtuHint: 1240 + i,
              );
            } finally {
              // No delay or explicit local flush before closing the connection.
              await client.close();
              await sub.cancel();
            }
            await waitUntil(
              () async {
                if (!await log.exists()) return false;
                return (await log.readAsLines()).any(
                  (line) =>
                      line.contains('ipc.mobile.network_changed') &&
                      line.contains(
                        'kind=${expected[i].$2} mtu_hint=${1240 + i}',
                      ),
                );
              },
              what: 'the daemon records this temporary client notification',
              timeout: const Duration(seconds: 10),
            );
            received++;
          }
          final lines = (await log.readAsLines()).where(
            (line) =>
                line.contains('ipc.mobile.network_changed') &&
                line.contains('mtu_hint='),
          );
          expect(lines, hasLength(expected.length));
          final adapter = await VeilFlutterTransport.connect(
            plan.ipcSocket(root.path),
          );
          final attachments = <NetworkAttachment>[];
          final subscription = adapter.networkAttachments.listen(
            attachments.add,
          );
          var dispatches = 0;
          final starts = adapter.networkChangeStarts.listen((_) {
            dispatches++;
          });
          try {
            if (!tcp) {
              adapter.observeNetworkAttachment(NetworkAttachment.wifi);
              await adapter.networkChanged(NetworkAttachment.wifi);
              await pumpEventQueue();
              expect(dispatches, 2);
              expect(attachments, isEmpty);
            }
            // Keep the connected adapter alive while temporary IPC cannot
            // open. TCP exercises failure of the first observation as well.
            final endpoint = File(
              tcp ? '${root.path}/ipc.port' : plan.ipcSocket(root.path),
            );
            final hiddenEndpoint = await endpoint.rename('${endpoint.path}.held');
            try {
              for (final change in [
                NetworkAttachment.offline,
                NetworkAttachment.offline,
                NetworkAttachment.cellular,
              ]) {
                await expectLater(adapter.networkChanged(change), throwsException);
              }
              await pumpEventQueue();
              expect(attachments, [NetworkAttachment.offline]);
            } finally {
              await hiddenEndpoint.rename(endpoint.path);
            }
            const changes = [
              NetworkAttachment.cellular,
              NetworkAttachment.offline,
              NetworkAttachment.wifi,
              NetworkAttachment.unknown,
            ];
            for (final change in changes) {
              final previous = adapter.networkChangeGeneration;
              final previousDispatches = dispatches;
              final dispatch = adapter.networkChanged(change);
              expect(adapter.networkChangeGeneration, previous + 1);
              expect(dispatches, previousDispatches + 1);
              await dispatch;
            }
            await pumpEventQueue();
            expect(attachments, [NetworkAttachment.offline, ...changes]);

            final stale = adapter.networkChanged(NetworkAttachment.ethernet);
            // The temporary client is still opening when this arrives.
            adapter.observeNetworkAttachment(NetworkAttachment.offline);
            await stale;
            await pumpEventQueue();
            final whileOffline = [
              NetworkAttachment.offline,
              ...changes,
              NetworkAttachment.offline,
            ];
            expect(attachments, whileOffline);

            adapter.observeNetworkAttachment(NetworkAttachment.cellular);
            await pumpEventQueue();
            expect(attachments, whileOffline);
            await adapter.networkChanged(NetworkAttachment.cellular);
            await pumpEventQueue();
            expect(attachments, [...whileOffline, NetworkAttachment.cellular]);
            // The newer dispatch has reached the daemon before its receipt.
            // A stale dispatch would also be visible by now and would reset
            // its sessions even though the app suppressed the stale result.
            final dispatched = (await log.readAsLines()).where(
              (line) => line.contains('ipc.mobile.network_changed kind='),
            );
            expect(dispatched.last, contains('kind=Cellular mtu_hint=0'));
            expect(
              dispatched.where(
                (line) => line.contains('kind=Ethernet mtu_hint=0'),
              ),
              isEmpty,
            );
          } finally {
            await starts.cancel();
            await subscription.cancel();
            await adapter.dispose();
          }
          final returning = await VeilFlutterTransport.connect(
            plan.ipcSocket(root.path),
          );
          final observedHandover = <NetworkAttachment>[];
          final returningSubscription = returning.networkAttachments.listen(
            observedHandover.add,
          );
          try {
            // A live node can already own calls while its network observer
            // first catches up. The first command never reaches the node.
            returning.observeNetworkAttachment(NetworkAttachment.wifi);
            final bootstrap = returning.networkChanged(NetworkAttachment.wifi);
            // Android can report a replacement with the same attachment kind.
            final next = tcp
                ? NetworkAttachment.wifi
                : NetworkAttachment.cellular;
            returning.observeNetworkAttachment(next);
            await bootstrap;
            await pumpEventQueue();
            expect(observedHandover, isEmpty);

            await returning.networkChanged(next);
            await pumpEventQueue();
            expect(observedHandover, [next]);
          } finally {
            await returningSubscription.cancel();
            await returning.dispose();
          }
          final control = await veil.VeilClient.connect(
            plan.ipcSocket(root.path),
          );
          try {
            expect(await control.nodeId(), hasLength(32));
          } finally {
            await control.close();
          }
        } finally {
          await controller.stop();
          if (tcp) {
            for (final name in [
              'admin.port',
              'admin.token',
              'ipc.port',
              'ipc.token',
            ]) {
              expect(await File('${root.path}/$name').exists(), false);
            }
            for (final port in ports) {
              final rebound = await ServerSocket.bind(
                InternetAddress.loopbackIPv4,
                port,
              );
              await rebound.close();
            }
          }
          await root.delete(recursive: true);
        }
        final evidence =
            Platform.environment['XVEIL_NETWORK_DISPATCH_EVIDENCE'];
        if (evidence != null) {
          await File('$evidence/${tcp ? 'tcp' : 'unix'}.json').writeAsString(
            jsonEncode({
              'authenticatedLoopbackTcp': tcp,
              'receivedNotifications': received,
              'temporaryClientClosedWithoutDelay': true,
              'freshClientControl': true,
              'nativeNodeStopped': true,
              'runtimeRemoved': !await root.exists(),
              'tcpPortsReboundAfterStop': ports.length,
            }),
          );
        }
      },
      skip: library == null || (!tcp && Platform.isWindows)
          ? 'set VEIL_FFI_DYLIB; Unix control needs a Unix host'
          : false,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
