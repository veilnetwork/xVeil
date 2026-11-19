import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/settings/storage_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

class _Controller extends AppController {
  int identity = 0;
  final enabled = <int, bool>{};
  final writes = <(int, bool)>[];
  Completer<void>? save;

  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  bool get canCompactStorage => true;
  @override
  IdentityLease leaseIdentity() => IdentityLease(null, 0, identity);
  @override
  bool holdsIdentity(IdentityLease lease) => lease.lifecycle == identity;
  @override
  Future<bool> autoCompactEnabled() async => enabled[identity] ?? false;

  @override
  Future<void> setAutoCompactEnabled(bool enabled) async {
    final owner = identity;
    writes.add((owner, enabled));
    await save?.future;
    this.enabled[owner] = enabled;
  }
}

void main() {
  final l = AppL10nEn();
  final setting = find.widgetWithText(
    SwitchListTile,
    l.settingsStorageAutoCompact,
  );

  Future<void> open(WidgetTester tester, _Controller controller) async {
    SharedPreferences.setMockInitialValues({});
    final storage = FakeHvContainer().storage();
    final app = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => controller),
        singleSpaceStorageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: app,
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: StorageSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(setting, findsOneWidget);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.text(l.settingsStorageAutoCompactConfirmAction));
    await tester.pumpAndSettle();
  }

  testWidgets('auto-compaction confirmation belongs to its original identity', (
    tester,
  ) async {
    final controller = _Controller();
    await open(tester, controller);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    controller.identity++;
    await confirm(tester);
    expect(controller.writes, isEmpty);
    expect(tester.widget<SwitchListTile>(setting).value, isFalse);

    await tester.tap(setting);
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(controller.writes, [(1, true)]);
    expect(tester.widget<SwitchListTile>(setting).value, isTrue);
  });

  for (final enable in [true, false]) {
    testWidgets(
      'auto-compaction shows stored state after refusal (enable=$enable)',
      (tester) async {
        final controller = _Controller()
          ..enabled[0] = !enable
          ..save = Completer<void>();
        await open(tester, controller);
        await tester.tap(setting);
        await tester.pumpAndSettle();
        if (enable) await confirm(tester);
        expect(controller.writes, [(0, enable)]);
        final pending = tester.widget<SwitchListTile>(setting);
        expect(pending.onChanged, isNull);
        controller.save!.completeError(StateError('fixture refusal'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(pending.value, !enable);
        expect(tester.widget<SwitchListTile>(setting).value, !enable);
        expect(tester.widget<SwitchListTile>(setting).onChanged, isNotNull);
        expect(find.text(l.dhtServeSaveFailed), findsOneWidget);
      },
    );
  }
}
