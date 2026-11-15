import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/state/messaging_core.dart';
import 'support/fake_hv_container.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/home/network_reach_banner.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/messaging_providers.dart';
import 'package:xveil/state/providers.dart';

class _Application extends AppController {
  _Application(this.phase);
  final AppPhase phase;
  @override
  AppState build() => AppState(
    phase,
    identity: Identity(nodeId: NodeId(Uint8List(32)..fillRange(0, 32, 1))),
  );
}

void main() {
  testWidgets(
    'network banner can remount after its cached controller changes',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      final messaging = MessagingService(LoopbackTransport(), storage);
      final show = ValueNotifier(true);
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(
            () => _Application(AppPhase.ready),
          ),
          singleSpaceStorageProvider.overrideWithValue(storage),
          messagingServiceProvider.overrideWithValue(messaging),
        ],
      );
      container.read(nodeBootStateProvider.notifier).state = const NodeStatus(
        phase: NodePhase.connected,
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: ValueListenableBuilder<bool>(
                valueListenable: show,
                builder: (_, visible, _) =>
                    visible ? const NetworkReachBanner() : const SizedBox(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          container.read(nodeStatusProvider).asData?.value.phase,
          NodePhase.connected,
        );
        show.value = false;
        await tester.pumpAndSettle();
        // The normal home route is absent while maintenance replaces the node.
        // Its always-alive stream retains a cached controller dependency.
        container.read(nodeBootStateProvider.notifier).state = const NodeStatus(
          phase: NodePhase.error,
        );
        await tester.pumpAndSettle();
        show.value = true;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          container.read(nodeStatusProvider).asData?.value.phase,
          NodePhase.error,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        show.dispose();
        await messaging.dispose();
        await storage.close();
      }
    },
  );

  for (final ending in [false, true]) {
    testWidgets(
      'network banner avoids session services when ${ending ? 'ending' : 'locked'}',
      (tester) async {
        var reads = 0;
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(
              () => _Application(ending ? AppPhase.ready : AppPhase.locked),
            ),
            nodeStatusProvider.overrideWith((ref) {
              reads++;
              throw StateError('network banner read a sealed session');
            }),
            messagingServiceProvider.overrideWith((ref) {
              reads++;
              throw StateError('network banner read a sealed session');
            }),
          ],
        );
        if (ending) container.read(sessionEndDepthProvider.notifier).state = 1;
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(home: NetworkReachBanner()),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(reads, 0);
        } finally {
          await tester.pumpWidget(const SizedBox());
          container.dispose();
        }
      },
    );
  }
}
