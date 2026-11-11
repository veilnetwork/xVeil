import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/features/settings/compaction_offer_dialog.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

class _ControlledCompaction extends AppController {
  _ControlledCompaction({
    required this.redirectOnRun,
    this.fastCollection = false,
  });
  final bool redirectOnRun;
  bool fastCollection;
  bool authorizationCurrent = true;
  int reopenCalls = 0;
  final collection = Completer<void>();
  final finish = Completer<void>();

  @override
  AppState build() => const AppState(AppPhase.ready);

  @override
  bool holdsIdentity(IdentityLease lease) =>
      authorizationCurrent && super.holdsIdentity(lease);

  @override
  Future<void> noteCompactionOffered({DateTime? at}) async {}

  @override
  Future<bool> beginCompactionCollection() async {
    state = const AppState(AppPhase.preparingNode);
    if (!fastCollection) await collection.future;
    return true;
  }

  @override
  Future<({int before, int after})> compactStorageKeeping({
    required CompactionRoster roster,
    required String reopenWith,
  }) async {
    // The real controller publishes ready during unlock, before the final
    // settings write/result has returned to the dialog.
    if (redirectOnRun) state = const AppState(AppPhase.ready);
    await finish.future;
    return (before: 1000, after: 100);
  }

  @override
  Future<void> cancelCompactionCollection(String password) async {
    reopenCalls++;
    state = const AppState(AppPhase.ready);
    await finish.future;
  }
}

enum _Scenario { redirect, popup, cancel, fastCollection, discarded, locked }

void main() {
  for (final scenario in _Scenario.values) {
    final redirect = scenario != _Scenario.popup;
    final cancel =
        scenario == _Scenario.cancel || scenario == _Scenario.discarded;
    final fast = scenario == _Scenario.fastCollection;
    final title = switch (scenario) {
      _Scenario.redirect =>
        'router replacement must await the actual compaction result',
      _Scenario.popup =>
        'completion closes its own dialog and preserves a newer popup',
      _Scenario.cancel =>
        'router replacement must await cancellation reopening too',
      _Scenario.fastCollection =>
        'immediate teardown keeps the collection on its prepared page',
      _Scenario.discarded =>
        'a discarded collection restores the closed session before returning',
      _Scenario.locked =>
        'a discarded collection must not restore an obsolete authorization',
    };
    testWidgets(title, (tester) async {
      final fixture = FakeHvContainer();
      final storage = fixture.storage();
      await storage.open(password: 'fixture', createIfMissing: true);
      await storage.saveProfile(const UserProfile(displayName: 'fixture'));
      await storage.close();
      final controller = _ControlledCompaction(
        redirectOnRun: redirect,
        fastCollection: fast,
      );
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => controller),
          storageProvider.overrideWith((ref) => fixture.storage()),
        ],
      );
      addTearDown(container.dispose);
      final refresh = ValueNotifier<int>(0);
      addTearDown(refresh.dispose);
      container.listen(appControllerProvider, (_, _) => refresh.value++);
      final navigator = GlobalKey<NavigatorState>();
      var completed = false;
      ({int before, int after})? result;
      final router = GoRouter(
        navigatorKey: navigator,
        initialLocation: '/home',
        refreshListenable: refresh,
        redirect: (_, state) {
          final destination =
              container.read(appControllerProvider).phase ==
                  AppPhase.preparingNode
              ? '/preparing'
              : '/home';
          return state.matchedLocation == destination ? null : destination;
        },
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  child: const Text('open'),
                  onPressed: () async {
                    result = await showCompactionOffer(
                      context,
                      ref,
                      estimate: const CompactionEstimate(
                        fileBytes: 1000,
                        liveBytes: 100,
                        identitiesCounted: 1,
                        identitiesKnown: 1,
                      ),
                      currentPassword: 'fixture',
                    );
                    completed = true;
                  },
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/preparing',
            builder: (_, _) => const Scaffold(body: Text('preparing')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('preparing'), findsOneWidget);
      controller.collection.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      if (scenario == _Scenario.discarded || scenario == _Scenario.locked) {
        final route = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
        if (scenario == _Scenario.locked) {
          // A lock/switch revoked this authorization. A new operation may be
          // in the same loading phase, but the old password must stay unused.
          controller.authorizationCurrent = false;
        }
        if (route.isActive) navigator.currentState!.removeRoute(route);
      } else {
        await tester.tap(
          find.text(
            cancel ? AppL10nEn().actionCancel : AppL10nEn().compactOfferRun,
          ),
        );
      }
      await tester.pumpAndSettle();
      if (scenario == _Scenario.locked) {
        expect(controller.reopenCalls, 0);
        expect(
          container.read(appControllerProvider).phase,
          AppPhase.preparingNode,
        );
        expect(completed, isTrue);
        expect(result, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }
      if (scenario == _Scenario.discarded) expect(controller.reopenCalls, 1);
      if (redirect) {
        expect(find.text('open'), findsOneWidget);
        expect(
          completed,
          isFalse,
          reason: 'the native operation is still held behind its result gate',
        );
      } else {
        // A background permission offer or another application popup can be
        // pushed while the operation is finishing. It does not belong to it.
        unawaited(
          showDialog<void>(
            context: navigator.currentContext!,
            builder: (_) => const AlertDialog(content: Text('newer-popup')),
          ),
        );
        await tester.pumpAndSettle();
      }
      controller.finish.complete();
      await tester.pumpAndSettle();
      if (!redirect) {
        expect(find.text('newer-popup'), findsOneWidget);
        expect(find.text(AppL10nEn().compactOfferTitle), findsNothing);
      }
      expect(completed, isTrue);
      expect(result, cancel ? null : (before: 1000, after: 100));
      if (!redirect) {
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('a disposed collection owner cannot reopen the container', () async {
    final controller = _ControlledCompaction(
      redirectOnRun: false,
      fastCollection: true,
    );
    final container = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => controller)],
    );
    container.read(appControllerProvider);
    final lease = controller.leaseIdentity();
    await controller.beginCompactionCollection();
    controller.finish.complete();
    container.dispose();
    await controller.recoverCompactionCollection(
      lease: lease,
      reopenWith: 'fixture',
    );
    expect(controller.reopenCalls, 0);
  });
}
