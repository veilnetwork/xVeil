import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/compaction_profile_authorization.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/features/settings/compaction_offer_dialog.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';

ManagedStorageLocator _root(int n, StorageProtection protection) =>
    ManagedStorageLocator(
      id: ManagedIdentityId('$n' * 32),
      protection: protection,
    );

class _Controller extends AppController {
  _Controller({this.uncertain = false});
  final bool uncertain;
  final encrypted = _root(1, StorageProtection.encrypted);
  final plain = _root(2, StorageProtection.unencrypted);
  final requests =
      <({ManagedStorageLocator identity, String password, bool approved})>[];
  CompactionProfileSnapshot? published;
  List<String>? hidden;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  List<ManagedStorageLocator> get compactionVisibleIdentities => [
    encrypted,
    plain,
  ];
  @override
  Future<void> noteCompactionOffered({DateTime? at}) async {}
  @override
  Future<bool> beginCompactionCollection() async => true;
  @override
  Future<void> cancelCompactionCollection(String password) async {}
  @override
  Future<
    ({
      bool opened,
      bool isMaster,
      String? displayName,
      String? username,
      List<String> subordinates,
      Uint8List? spaceKeys,
      List<({String label, List<int> keys})> children,
    })
  >
  probeCompactionIdentity(String password) async => (
    opened: ['master-fixture', 'child-fixture'].contains(password),
    isMaster: false,
    displayName: password,
    username: null,
    subordinates: <String>[],
    spaceKeys: Uint8List.fromList(
      List.filled(64, password == 'master-fixture' ? 1 : 2),
    ),
    children: <({String label, List<int> keys})>[],
  );
  @override
  Future<
    ({
      Uint8List keys,
      String? name,
      List<({String label, List<int> keys})> children,
    })?
  >
  probeCompactionVisibleIdentity(
    ManagedStorageLocator identity, {
    String password = '',
    bool plaintextApproved = false,
  }) async {
    requests.add((
      identity: identity,
      password: password,
      approved: plaintextApproved,
    ));
    return (
      keys: Uint8List.fromList(List.filled(64, identity == plain ? 4 : 3)),
      name: identity == plain ? 'Plain fixture' : 'Encrypted fixture',
      children: [(label: 'Hidden child', keys: List.filled(64, 2))],
    );
  }

  @override
  Future<({int before, int after})> compactStorageKeepingWithProfile({
    required CompactionRoster roster,
    required String reopenWith,
    required CompactionProfileAuthorization profileAuthorization,
  }) async {
    published = profileAuthorization.snapshot();
    hidden = roster.passwords().map(String.fromCharCodes).toList();
    if (uncertain) {
      throw const ManagedLegacyCompactionFailure(
        ManagedWorkerFailureKind.backend,
        mayHaveApplied: true,
        recovery: null,
      );
    }
    return (before: 100, after: 10);
  }

  @override
  Future<({int before, int after})> compactStorageKeeping({
    required CompactionRoster roster,
    required String reopenWith,
  }) async => throw StateError('mixed UI used the legacy publisher');
}

void main() {
  for (final uncertain in [false, true]) {
    testWidgets(
      'mixed dialog requires complete authority and handles uncertain outcome ($uncertain)',
      (tester) async {
        tester.view.physicalSize = const Size(380, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = _Controller(uncertain: uncertain);
        final l = AppL10nEn();
        Object? result;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appControllerProvider.overrideWith(() => controller)],
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: TextButton(
                    child: const Text('Open'),
                    onPressed: () async => result = await showCompactionOffer(
                      context,
                      ref,
                      estimate: const CompactionEstimate(
                        fileBytes: 100,
                        liveBytes: 10,
                        identitiesCounted: 1,
                        identitiesKnown: 1,
                      ),
                      currentPassword: 'master-fixture',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        FilledButton run() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, l.compactOfferRun),
        );
        expect(run().onPressed, isNull);
        expect(
          controller.requests,
          isEmpty,
        ); // Plaintext is never auto-authorized.
        final plain = find.byKey(
          ValueKey('compaction-owner-${controller.plain.id.value}'),
        );
        await tester.ensureVisible(plain);
        await tester.tap(plain);
        await tester.pumpAndSettle();
        expect(controller.requests.single, (
          identity: controller.plain,
          password: '',
          approved: true,
        ));
        expect(run().onPressed, isNull);
        final encrypted = find.byKey(
          ValueKey('compaction-owner-${controller.encrypted.id.value}'),
        );
        await tester.ensureVisible(encrypted);
        await tester.tap(encrypted);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'visible-fixture');
        await tester.tap(find.widgetWithText(FilledButton, l.compactOfferAdd));
        await tester.pumpAndSettle();
        expect(controller.requests.last, (
          identity: controller.encrypted,
          password: 'visible-fixture',
          approved: false,
        ));
        expect(
          run().onPressed,
          isNull,
        ); // Both visible roots still need hidden child coverage.
        expect(find.text('Hidden child'), findsOneWidget);
        await tester.ensureVisible(find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'child-fixture');
        await tester.tap(find.widgetWithText(TextButton, l.compactOfferAdd));
        await tester.pumpAndSettle();
        expect(run().onPressed, isNotNull);
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, l.compactOfferRun),
        );
        await tester.tap(find.widgetWithText(FilledButton, l.compactOfferRun));
        await tester.pumpAndSettle();
        if (uncertain) {
          expect(find.text(l.compactOfferOutcomeUncertain), findsOneWidget);
          expect(run().onPressed, isNull);
          await tester.tap(find.widgetWithText(TextButton, l.actionCancel));
          await tester.pumpAndSettle();
          expect(result, isNull);
        } else {
          expect(result, (before: 100, after: 10));
        }
        expect(controller.published!.plaintextApproved, {controller.plain.id});
        expect(controller.published!.authorizations.keys.toSet(), {
          controller.plain.id,
          controller.encrypted.id,
        });
        expect(controller.hidden, ['master-fixture', 'child-fixture']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
