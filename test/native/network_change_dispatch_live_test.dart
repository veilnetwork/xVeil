// Real embedded node + native FFI; the blocked-wait oracle lives in the SDK.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
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
