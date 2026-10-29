import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/app.dart';
import 'package:xveil/state/model_exchange_service.dart';

import 'support/fake_messaging.dart';
import 'support/fake_setting_storage.dart';

void main() {
  testWidgets(
    'model inventory responder is attached without visiting settings',
    (tester) async {
      final messaging = FakeMessagingForModels();
      var constructed = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            modelExchangeServiceProvider.overrideWith((ref) {
              constructed++;
              final service = ModelExchangeService(
                messaging: messaging,
                storage: FakeSettingStorage(),
                translateRoot: () async => null,
                speechRoot: () async => null,
                now: DateTime.now,
              );
              ref.onDispose(service.dispose);
              return service;
            }),
          ],
          child: const XVeilApp(),
        ),
      );
      await tester.pump();
      expect(constructed, 1);
      expect(messaging.onModelInventoryRequest, isNotNull);
      expect(messaging.onModelInventoryOffer, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets('boots to the splash screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: XVeilApp()));
    await tester.pump();
    // Splash shows a spinner while bootstrapping.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
