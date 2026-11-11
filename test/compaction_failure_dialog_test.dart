import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/features/settings/compaction_offer_dialog.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

class _FailedCompaction extends AppController {
  _FailedCompaction({this.incomplete = false, this.failEntry});
  final bool incomplete;
  final String? failEntry;
  bool cancelled = false;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<void> noteCompactionOffered({DateTime? at}) async {
    if (failEntry == 'note') throw StateError('fixture entry failure');
  }

  @override
  Future<bool> beginCompactionCollection() async {
    if (failEntry == 'begin') throw StateError('fixture maintenance busy');
    return true;
  }

  @override
  Future<void> cancelCompactionCollection(String password) async {
    cancelled = true;
  }

  @override
  Future<({int before, int after})> compactStorageKeeping({
    required CompactionRoster roster,
    required String reopenWith,
  }) async {
    if (incomplete) throw const CompactionRosterRepairIncomplete();
    throw StateError('fixture rewrite failure');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    errorJournal.clear();
  });
  for (final stage in ['note', 'begin']) {
    testWidgets('entry failure is visible and owns no recovery ($stage)', (
      tester,
    ) async {
      final controller = _FailedCompaction(failEntry: stage);
      var returned = false;
      Object? result = 'pending';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith(() => controller)],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showCompactionOffer(
                      context,
                      ref,
                      estimate: const CompactionEstimate(
                        fileBytes: 100,
                        liveBytes: 10,
                        identitiesCounted: 1,
                        identitiesKnown: 1,
                      ),
                      currentPassword: 'fixture',
                    );
                    returned = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(returned, isTrue);
      expect(result, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text(AppL10nEn().settingsStorageCompactFailed),
        findsOneWidget,
      );
      expect(
        controller.cancelled,
        isFalse,
        reason: 'a rejected caller must not reopen another collection',
      );
      expect(errorJournal.entries.single.kind, 'storage-compaction-entry');
    });
  }
  test(
    'collection cannot drop the identity used to reopen the container',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final roster = CompactionRoster()
        ..addUnlocked('other', passwordBytes: [1, 2]);
      await expectLater(
        container
            .read(appControllerProvider.notifier)
            .compactStorageKeeping(
              roster: roster,
              reopenWith: 'current-fixture',
            ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('reopen password'),
          ),
        ),
      );
    },
  );
  for (final incomplete in [false, true]) {
    testWidgets('failure leaves a usable dialog (repair=$incomplete)', (
      tester,
    ) async {
      final fixture = FakeHvContainer();
      final space = fixture.storage();
      await space.open(password: 'fixture', createIfMissing: true);
      await space.saveProfile(const UserProfile(displayName: 'fixture'));
      await space.close();
      final controller = _FailedCompaction(incomplete: incomplete);
      final l = AppL10nEn();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            storageProvider.overrideWith((ref) => fixture.storage()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () => showCompactionOffer(
                    context,
                    ref,
                    estimate: const CompactionEstimate(
                      fileBytes: 100,
                      liveBytes: 10,
                      identitiesCounted: 1,
                      identitiesKnown: 1,
                    ),
                    currentPassword: 'fixture',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: 'system back must not strand a closed container',
      );
      await tester.tap(find.text(l.compactOfferRun));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          incomplete
              ? l.settingsStorageCompactRepairIncomplete
              : l.settingsStorageCompactFailed,
        ),
        findsOneWidget,
      );
      final export =
          jsonDecode(
                errorJournal.toJson(
                  platform: 'android',
                  osVersion: 'unknown',
                  appVersion: 'test',
                  phase: 'settings',
                  includeTimestamps: false,
                ),
              )
              as Map<String, dynamic>;
      final recorded =
          (export['errors'] as List).single as Map<String, dynamic>;
      expect(recorded['kind'], 'storage-compaction');
      expect(
        recorded['type'],
        incomplete ? 'CompactionRosterRepairIncomplete' : 'StateError',
      );
      expect(recorded.keys.every({'kind', 'type', 'frames'}.contains), isTrue);
      final cancel = tester.widget<TextButton>(
        find.widgetWithText(TextButton, l.actionCancel),
      );
      expect(cancel.onPressed, isNotNull);
      await tester.tap(find.text(l.actionCancel));
      await tester.pumpAndSettle();
      expect(
        controller.cancelled,
        isFalse,
        reason: 'the controller already reopened after the failed rewrite',
      );
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  test(
    'the same password or space cannot be collected under another label',
    () {
      final keys = Uint8List(64)..[0] = 7;
      final roster = CompactionRoster();
      expect(
        roster.addUnlocked('first', passwordBytes: [1, 2], spaceKeys: keys),
        true,
      );
      expect(
        roster.addUnlocked('repeat', passwordBytes: [1, 2], spaceKeys: keys),
        false,
      );
      expect(
        roster.addUnlocked('alias', passwordBytes: [3], spaceKeys: keys),
        false,
      );
      expect(roster.length, 1);
    },
  );
}
