import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
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
