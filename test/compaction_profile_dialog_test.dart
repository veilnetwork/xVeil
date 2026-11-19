import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/update/app_update.dart';
import 'package:xveil/features/home/home_shell.dart';
import 'package:xveil/features/settings/storage_settings_screen.dart';
import 'package:xveil/state/app_update_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/whisper_model_controller.dart';
import 'support/fake_hv_container.dart';
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
  _Controller({
    this.uncertain = false,
    this.admissionFailure = false,
    this.access = 'legacy',
    this.recoveryGate,
  });
  final String access;
  final Completer<void>? recoveryGate;
  final recoveryStarted = Completer<void>();
  String? reopenPassword;
  final hiddenProbeRequests = <String>[];
  final bool uncertain, admissionFailure;
  int recoveryCalls = 0;
  AppPhase get observedPhase => state.phase;
  final encrypted = _root(1, StorageProtection.encrypted);
  final plain = _root(2, StorageProtection.unencrypted);
  final requests =
      <({ManagedStorageLocator identity, String password, bool approved})>[];
  CompactionProfileSnapshot? published;
  List<String>? hidden;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  IdentityStorageLocator get compactionAccessLocator => switch (access) {
    'encrypted' => encrypted,
    'plain' => plain,
    _ => const LegacyStorageLocator(),
  };
  @override
  List<ManagedStorageLocator> get compactionVisibleIdentities => [
    encrypted,
    plain,
  ];
  @override
  Future<void> noteCompactionOffered({DateTime? at}) async {}
  @override
  Future<bool> beginCompactionCollection() async {
    state = const AppState(AppPhase.preparingNode);
    return true;
  }

  @override
  Future<void> cancelCompactionCollection(String password) async {
    recoveryCalls++;
    if (!recoveryStarted.isCompleted) recoveryStarted.complete();
    await recoveryGate?.future;
    state = const AppState(AppPhase.ready);
  }

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
  probeCompactionIdentity(String password) async {
    hiddenProbeRequests.add(password);
    return (
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
  }

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
    reopenPassword = reopenWith;
    published = profileAuthorization.snapshot();
    hidden = roster.passwords().map(String.fromCharCodes).toList();
    if (admissionFailure) throw StateError('fixture admission refused');
    if (uncertain) {
      throw const ManagedLegacyCompactionFailure(
        ManagedWorkerFailureKind.backend,
        mayHaveApplied: true,
        recovery: null,
      );
    }
    state = const AppState(AppPhase.ready);
    return (before: 100, after: 10);
  }

  @override
  Future<({int before, int after})> compactStorageKeeping({
    required CompactionRoster roster,
    required String reopenWith,
  }) async => throw StateError('mixed UI used the legacy publisher');
}

class _ScreenController extends _Controller {
  _ScreenController({this.solo = false});
  final bool solo;
  int identity = 0;
  int collectionStarts = 0;
  Completer<void>? estimateGate;
  final waitingForEstimate = Completer<void>();
  final finish = Completer<void>();
  final started = Completer<void>();
  @override
  bool get canCompactStorage => solo;
  @override
  IdentityLease leaseIdentity() => IdentityLease(null, 0, identity);
  @override
  bool holdsIdentity(IdentityLease lease) => lease.lifecycle == identity;
  @override
  Future<bool> beginCompactionCollection() {
    collectionStarts++;
    return super.beginCompactionCollection();
  }
  @override
  List<ManagedStorageLocator> get compactionVisibleIdentities => [];
  @override
  Future<({CompactionOfferVerdict verdict, CompactionEstimate estimate})?>
  compactionOffer({DateTime? now}) async {
    final gate = estimateGate;
    if (gate != null) {
      if (!waitingForEstimate.isCompleted) waitingForEstimate.complete();
      await gate.future;
    }
    return (
      verdict: CompactionOfferVerdict.offer,
      estimate: const CompactionEstimate(
        fileBytes: 100,
        liveBytes: 10,
        identitiesCounted: 1,
        identitiesKnown: 1,
      ),
    );
  }
  @override
  Future<({int before, int after})> compactStorageKeeping({
    required CompactionRoster roster,
    required String reopenWith,
  }) async {
    started.complete();
    await finish.future;
    return (before: 100, after: 10);
  }
}

class _NoUpdates extends AppUpdateController {
  @override
  Future<void> checkIfDue({DateTime? now, AppUpdateChecker? checker}) async {}
}

class _NoSpeechDownload extends WhisperModelController {
  @override
  WhisperModelState build() => const WhisperModelState();
  @override
  Future<void> ensureDownloadedInBackground() async {}
}

void main() {
  for (final step in ['estimate', 'banner', 'password']) {
    testWidgets('home compaction drops a retired $step', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final ctrl = _ScreenController();
      final l = AppL10nEn();
      if (step == 'estimate') ctrl.estimateGate = Completer<void>();
      Future<void> frame() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
      }
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => ctrl),
          appUpdateProvider.overrideWith(_NoUpdates.new),
          whisperModelControllerProvider.overrideWith(_NoSpeechDownload.new),
          singleSpaceStorageProvider.overrideWithValue(FakeHvContainer().storage()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: HomeShell(),
          ),
        ),
      );
      await frame();
      if (step == 'estimate') {
        expect(ctrl.waitingForEstimate.isCompleted, isTrue);
        ctrl.identity++;
        ctrl.estimateGate!.complete();
        await frame();
        expect(find.byType(MaterialBanner), findsNothing);
        expect(ctrl.collectionStarts, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }
      expect(find.byType(MaterialBanner), findsOneWidget);
      if (step == 'banner') ctrl.identity++;
      await tester.tap(find.widgetWithText(TextButton, l.compactOfferRun));
      await frame();
      if (step == 'password') {
        expect(find.byType(CompactPasswordDialog), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'previous-fixture');
        ctrl.identity++;
        await tester.tap(find.widgetWithText(FilledButton, l.actionContinue));
        await frame();
      }
      expect(find.byType(AlertDialog), findsNothing);
      expect(ctrl.collectionStarts, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final solo in [true, false]) {
    for (final step in ['password', 'estimate']) {
      testWidgets('settings compaction drops a retired $step (solo=$solo)', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final ctrl = _ScreenController(solo: solo);
        final l = AppL10nEn();
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => ctrl),
            singleSpaceStorageProvider.overrideWithValue(FakeHvContainer().storage()),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: StorageSettingsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tile = find.widgetWithText(
          ListTile,
          solo ? l.settingsStorageCompact : l.compactOfferTitle,
        );
        await tester.tap(tile);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'previous-fixture');
        if (step == 'password') {
          ctrl.identity++;
        } else {
          ctrl.estimateGate = Completer<void>();
        }
        await tester.tap(
          find.widgetWithText(
            FilledButton,
            solo ? l.settingsStorageCompact : l.actionContinue,
          ),
        );
        await tester.pumpAndSettle();
        if (step == 'estimate') {
          expect(ctrl.waitingForEstimate.isCompleted, isTrue);
          ctrl.identity++;
          ctrl.estimateGate!.complete();
          await tester.pumpAndSettle();
        }
        expect(ctrl.collectionStarts, 0);
        expect(ctrl.observedPhase, AppPhase.ready);
        expect(find.byType(CompactPasswordDialog), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
      });
    }
  }

  testWidgets(
    'compaction completion does not reload a replaced settings screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      final ctrl = _ScreenController();
      final visible = ValueNotifier(true);
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => ctrl),
          singleSpaceStorageProvider.overrideWithValue(storage),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              locale: const Locale('en'),
              home: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, show, _) => show
                    ? const StorageSettingsScreen()
                    : const Scaffold(body: SizedBox()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l = AppL10nEn();
        final offer = find.widgetWithText(ListTile, l.compactOfferTitle);
        await tester.scrollUntilVisible(
          offer,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(offer);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'master-fixture');
        await tester.tap(find.text(l.actionContinue));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, l.compactOfferRun),
        );
        await tester.tap(find.widgetWithText(FilledButton, l.compactOfferRun));
        await tester.pump();
        expect(ctrl.started.isCompleted, isTrue);
        visible.value =
            false; // /preparing replaces the original settings route.
        await tester.pump();
        expect(find.byType(StorageSettingsScreen), findsNothing);
        ctrl.finish.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        if (!ctrl.finish.isCompleted) ctrl.finish.complete();
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        visible.dispose();
        await storage.close();
      }
    },
  );

  for (final mode in [
    'success',
    'uncertain',
    'admission',
    'encrypted-access',
    'plain-access',
    'gated-admission',
  ]) {
    final uncertain = mode == 'uncertain';
    final admission = mode.endsWith('admission');
    final access = mode == 'encrypted-access'
        ? 'encrypted'
        : mode == 'plain-access'
        ? 'plain'
        : 'legacy';
    final currentPassword = access == 'encrypted'
        ? 'visible-fixture'
        : access == 'plain'
        ? ''
        : 'master-fixture';
    testWidgets(
      'mixed dialog requires complete authority and handles outcome ($mode)',
      (tester) async {
        tester.view.physicalSize = const Size(380, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = _Controller(
          uncertain: uncertain,
          admissionFailure: admission,
          access: access,
          recoveryGate: mode == 'gated-admission' ? Completer<void>() : null,
        );
        final l = AppL10nEn();
        Object? result = 'pending';
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
                      currentPassword: currentPassword,
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
        // An encrypted access password authorizes that owner, never a hidden
        // keep-set entry. Plaintext requires an explicit action in every mode.
        expect(
          controller.requests.where(
            (request) => request.identity == controller.plain,
          ),
          isEmpty,
        );
        if (access == 'encrypted') {
          expect(controller.requests.single, (
            identity: controller.encrypted,
            password: currentPassword,
            approved: false,
          ));
        } else {
          expect(controller.requests, isEmpty);
        }
        if (access != 'legacy') {
          expect(controller.hiddenProbeRequests, isEmpty);
          await tester.ensureVisible(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'master-fixture');
          await tester.tap(
            find.widgetWithText(TextButton, l.compactOfferAdd).first,
          );
          await tester.pumpAndSettle();
        }
        final plain = find.byKey(
          ValueKey('compaction-owner-${controller.plain.id.value}'),
        );
        await tester.ensureVisible(plain);
        await tester.tap(plain);
        await tester.pumpAndSettle();
        expect(
          controller.requests
              .where((request) => request.identity == controller.plain)
              .single,
          (identity: controller.plain, password: '', approved: true),
        );
        expect(run().onPressed, isNull);
        if (access != 'encrypted') {
          final encrypted = find.byKey(
            ValueKey('compaction-owner-${controller.encrypted.id.value}'),
          );
          await tester.ensureVisible(encrypted);
          await tester.tap(encrypted);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextField).last,
            'visible-fixture',
          );
          await tester.tap(
            find.widgetWithText(FilledButton, l.compactOfferAdd),
          );
          await tester.pumpAndSettle();
          expect(
            controller.requests
                .where((request) => request.identity == controller.encrypted)
                .single,
            (
              identity: controller.encrypted,
              password: 'visible-fixture',
              approved: false,
            ),
          );
        }
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
        if (mode == 'gated-admission') {
          try {
            expect(controller.recoveryStarted.isCompleted, isTrue);
            Navigator.of(
              tester.element(find.byType(AlertDialog)),
              rootNavigator: true,
            ).pop();
            await tester.pumpAndSettle();
            expect(result, 'pending');
          } finally {
            controller.recoveryGate!.complete();
          }
          await tester.pumpAndSettle();
          expect(result, isNull);
          expect(controller.recoveryCalls, 1);
          expect(controller.observedPhase, AppPhase.ready);
        } else if (uncertain || admission) {
          expect(
            find.text(
              uncertain
                  ? l.compactOfferOutcomeUncertain
                  : l.settingsStorageCompactFailed,
            ),
            findsOneWidget,
          );
          expect(controller.recoveryCalls, admission ? 1 : 0);
          expect(
            controller.observedPhase,
            admission ? AppPhase.ready : AppPhase.preparingNode,
          );
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
        expect(controller.reopenPassword, currentPassword);
        expect(
          controller.hiddenProbeRequests,
          isNot(contains('visible-fixture')),
        );
        expect(controller.hiddenProbeRequests, isNot(contains('')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
