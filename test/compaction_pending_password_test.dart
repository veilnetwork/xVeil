import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/features/settings/compaction_offer_dialog.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

typedef _Probe = ({
  bool opened,
  bool isMaster,
  String? displayName,
  String? username,
  List<String> subordinates,
  Uint8List? spaceKeys,
  List<({String label, List<int> keys})> children,
});

class _Controller extends AppController {
  bool authorized = true;
  final kept = <List<String>>[];
  int cancelled = 0;
  int probes = 0;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool parkHidden = false;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  bool holdsIdentity(IdentityLease lease) =>
      authorized && super.holdsIdentity(lease);
  @override
  Future<void> noteCompactionOffered({DateTime? at}) async {}
  @override
  Future<bool> beginCompactionCollection() async => true;
  @override
  Future<void> cancelCompactionCollection(String password) async {
    cancelled++;
  }

  @override
  Future<_Probe> probeCompactionIdentity(String password) async {
    probes++;
    if (parkHidden && password == 'hidden-fixture') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.probeCompactionIdentity(password);
  }

  @override
  Future<({int before, int after})> compactStorageKeeping({
    required CompactionRoster roster,
    required String reopenWith,
  }) async {
    kept.add(roster.passwords().map(utf8.decode).toList()..sort());
    return (before: 100, after: 20);
  }
}

Future<void> _dialog(WidgetTester tester, _Controller ctrl) async {
  final fixture = FakeHvContainer();
  Uint8List? hiddenKeys;
  for (final entry in {
    'open-fixture': 'Open',
    'hidden-fixture': 'Hidden',
    'master-fixture': 'Master',
  }.entries) {
    final store = fixture.storage();
    await store.open(password: entry.key, createIfMissing: true);
    await store.saveProfile(UserProfile(displayName: entry.value));
    if (entry.value == 'Hidden') hiddenKeys = await store.exportSpaceKeys();
    if (entry.value == 'Master') {
      await store.saveRoster([
        RosterEntry(label: 'Hidden', spaceKeys: hiddenKeys!),
      ]);
    }
    await store.close();
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appControllerProvider.overrideWith(() => ctrl),
        storageProvider.overrideWith((ref) => fixture.storage()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              child: const Text('open'),
              onPressed: () => showCompactionOffer(
                context,
                ref,
                estimate: const CompactionEstimate(
                  fileBytes: 100,
                  liveBytes: 10,
                  identitiesCounted: 1,
                  identitiesKnown: 0,
                ),
                currentPassword: 'open-fixture',
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('Open'), findsOneWidget);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final l = AppL10nEn();
  for (final password in [
    'hidden-fixture',
    'wrong-fixture',
    'open-fixture',
    'master-fixture',
  ]) {
    testWidgets('run checks the unsubmitted password: $password', (
      tester,
    ) async {
      final ctrl = _Controller();
      await _dialog(tester, ctrl);
      await tester.enterText(find.byType(TextField), password);
      await tester.tap(find.text(l.compactOfferRun));
      await tester.pumpAndSettle();
      if (password == 'hidden-fixture') {
        expect(ctrl.kept, [
          ['hidden-fixture', 'open-fixture'],
        ], reason: 'the typed hidden password was silently discarded');
      } else {
        expect(ctrl.kept, isEmpty);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        if (password == 'wrong-fixture') {
          expect(find.text(l.compactOfferUnknown), findsOneWidget);
        }
        if (password == 'open-fixture') {
          expect(find.text(l.compactOfferAlready), findsOneWidget);
        }
        if (password == 'master-fixture') {
          expect(find.text('Hidden'), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, l.compactOfferRun),
                )
                .onPressed,
            isNull,
          );
        }
        await tester.tap(find.text(l.actionCancel));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a late password check cannot start rewrite after lock', (
    tester,
  ) async {
    final ctrl = _Controller()..parkHidden = true;
    await _dialog(tester, ctrl);
    await tester.enterText(find.byType(TextField), 'hidden-fixture');
    await tester.tap(find.text(l.compactOfferRun));
    await tester.pumpAndSettle();
    try {
      expect(ctrl.entered.isCompleted, isTrue);
      ctrl.authorized = false;
    } finally {
      ctrl.release.complete();
      await tester.pumpAndSettle();
    }
    expect(ctrl.kept, isEmpty);
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();
    expect(
      ctrl.cancelled,
      0,
      reason: 'closing the old dialog must not unlock it',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('two input events start only one password probe', (tester) async {
    final ctrl = _Controller()..parkHidden = true;
    await _dialog(tester, ctrl);
    await tester.enterText(find.byType(TextField), 'hidden-fixture');
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, l.compactOfferAdd),
    );
    button.onPressed!();
    button.onPressed!();
    try {
      expect(ctrl.probes, 2, reason: 'one initial and one hidden probe');
    } finally {
      ctrl.release.complete();
      await tester.pumpAndSettle();
    }
    expect(find.text('Hidden'), findsOneWidget);
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing an obsolete collection never unlocks it', (
    tester,
  ) async {
    final ctrl = _Controller();
    await _dialog(tester, ctrl);
    ctrl.authorized = false;
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();
    expect(ctrl.cancelled, 0);
    expect(ctrl.kept, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a password result from an ended session is ignored', (
    tester,
  ) async {
    final ctrl = _Controller()..parkHidden = true;
    await _dialog(tester, ctrl);
    await tester.enterText(find.byType(TextField), 'hidden-fixture');
    await tester.tap(find.text(l.compactOfferAdd));
    await tester.pumpAndSettle();
    expect(ctrl.entered.isCompleted, isTrue);
    ctrl.authorized = false;
    ctrl.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('Hidden'), findsNothing);
    expect(ctrl.kept, isEmpty);
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();
    expect(ctrl.cancelled, 0);
  });
}
