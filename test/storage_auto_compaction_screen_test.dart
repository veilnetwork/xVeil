import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
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
  final offerWrites = <(int, CompactionOfferSettings)>[];
  Completer<void>? saveOffer;

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

  @override
  Future<void> setCompactionOfferSettings(
    CompactionOfferSettings settings,
  ) async {
    offerWrites.add((identity, settings));
    await saveOffer?.future;
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

  for (final period in [true, false]) {
    testWidgets(
      'an open offer setting dialog belongs to its identity (period=$period)',
      (tester) async {
        final controller = _Controller();
        await open(tester, controller);
        final setting = find.text(
          period
              ? l.settingsCompactOfferPeriod
              : l.settingsCompactOfferThreshold,
        );
        await tester.scrollUntilVisible(setting, 180);
        await tester.tap(setting);
        await tester.pumpAndSettle();
        controller.identity++;
        final choice = find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(
            period ? l.settingsCompactOfferDays(14) : fmtBytes(2 << 30),
          ),
        );
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(controller.offerWrites, isEmpty);

        await tester.tap(setting);
        await tester.pumpAndSettle();
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(controller.offerWrites.single.$1, 1);
        final saved = controller.offerWrites.single.$2;
        if (period) {
          expect(saved.period, const Duration(days: 14));
        } else {
          expect(saved.thresholdBytes, 2 << 30);
        }
      },
    );
  }

  testWidgets('offer switch still shows the saved setting after a refusal', (
    tester,
  ) async {
    final controller = _Controller()..saveOffer = Completer<void>();
    await open(tester, controller);
    final setting = find.widgetWithText(SwitchListTile, l.settingsCompactOffer);
    await tester.scrollUntilVisible(setting, 180);
    await tester.tap(setting);
    await tester.pumpAndSettle();
    expect(controller.offerWrites.single.$2.enabled, isFalse);
    expect(tester.widget<SwitchListTile>(setting).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(setting).value, isTrue);

    controller.saveOffer!.completeError(StateError('fixture refusal'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<SwitchListTile>(setting).value, isTrue);
    expect(tester.widget<SwitchListTile>(setting).onChanged, isNotNull);
    expect(find.text(l.dhtServeSaveFailed), findsOneWidget);
  });

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
