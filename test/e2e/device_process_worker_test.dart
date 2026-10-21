@Timeout(Duration(hours: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/debug/soak_hook.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

/// One native node per OS process, driven through the app's existing debug
/// API. Only the ready/unlock seam is supplied by the fixture. No identity
/// document cache or SharedPreferences instance is shared with another device.
void main() {
  final env = Platform.environment;
  final label = env['XVEIL_E2E_WORKER_LABEL'];
  testWidgets('isolated device process worker', (tester) async {
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
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    } finally {
      await tester.runAsync(() async => device?.stop());
    }
  }, skip: label == null || !E2eGate.read().enabled);
}
