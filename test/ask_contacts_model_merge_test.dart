import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/common/ask_contacts_for_models_sheet.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/cloud_service.dart';
import 'package:xveil/state/model_exchange_service.dart';

import 'support/fake_messaging.dart';
import 'support/fake_setting_storage.dart';

class _Cloud implements CloudService {
  _Cloud(this.peer);
  final NodeId peer;
  @override
  Future<List<Contact>> acceptedContacts() async => [
    Contact(nodeId: peer, name: 'Contact'),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('later sibling inventory preserves earlier visible model rows', (
    tester,
  ) async {
    final peer = NodeId.fromHex('a' * 64);
    final messaging = FakeMessagingForModels();
    final service = ModelExchangeService(
      messaging: messaging,
      storage: FakeSettingStorage(),
      translateRoot: () async => null,
      speechRoot: () async => null,
      now: DateTime.now,
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelExchangeServiceProvider.overrideWithValue(service),
          cloudServiceProvider.overrideWithValue(_Cloud(peer)),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAskContactsForModels(context),
                child: const Text('Find models'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Find models'));
    await _frames(tester);
    expect(messaging.asked, [peer]);
    final first = {'kind': 'translate', 'from': 'ru', 'to': 'en', 'bytes': 100};
    messaging.onModelInventoryOffer!(peer, jsonEncode([first]));
    await _frames(tester);
    expect(find.text('ru → en'), findsOneWidget);
    messaging.onModelInventoryOffer!(peer, '[{"kind":"speech","bytes":200}]');
    await _frames(tester);
    expect(find.text('ru → en'), findsOneWidget);
    expect(find.text('speech'), findsOneWidget);
    messaging.onModelInventoryOffer!(peer, jsonEncode([first, first]));
    await _frames(tester);
    expect(find.text('ru → en'), findsOneWidget);
    expect(find.text('speech'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
  });
}
