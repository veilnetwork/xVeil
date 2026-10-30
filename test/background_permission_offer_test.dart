import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/network/background_permission_offer.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/background_node_controller.dart';

void main() {
  group('shouldOfferBackgroundPermission', () {
    test('an OS exemption alone does not enable the background node', () {
      expect(
        shouldOfferBackgroundPermission(
          onAndroid: true,
          exempt: true,
          suppressed: false,
        ),
        isTrue,
      );
    });

    test('only offers unfinished setup without an explicit opt-out', () {
      for (final android in [false, true]) {
        for (final exempt in [false, true]) {
          for (final suppressed in [false, true]) {
            for (final enabled in <bool?>[null, false, true]) {
              final expected =
                  android &&
                  !suppressed &&
                  (enabled == null || (enabled && !exempt));
              expect(
                shouldOfferBackgroundPermission(
                  onAndroid: android,
                  exempt: exempt,
                  suppressed: suppressed,
                  backgroundEnabled: enabled,
                ),
                expected,
                reason:
                    'android=$android exempt=$exempt '
                    'suppressed=$suppressed enabled=$enabled',
              );
            }
          }
        }
      }
    });
  });

  Future<Future<void> Function()> mountOffer(
    WidgetTester tester, {
    required Future<void> Function() enable,
    required Future<void> Function() request,
    required Future<void> Function() settings,
  }) async {
    late BuildContext home;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              home = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final done = showBackgroundPermissionOffer(
      home,
      enableBackground: enable,
      requestExemption: request,
      openSettings: settings,
    );
    await tester.pumpAndSettle();
    return () => done;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Allow persists the real node choice before requesting exemption',
    (tester) async {
      final container = ProviderContainer();
      Object? enableError;
      bool? persistedAtRequest;
      bool? stateAtRequest;
      addTearDown(container.dispose);
      var requested = false;
      var settings = false;
      final done = await mountOffer(
        tester,
        enable: () async {
          try {
            await container.read(backgroundNodeProvider.notifier).set(true);
          } catch (e) {
            enableError = e;
            rethrow;
          }
        },
        request: () async {
          final prefs = await SharedPreferences.getInstance();
          persistedAtRequest = prefs.getBool(kKeepNodeBackgroundPrefKey);
          stateAtRequest = container.read(backgroundNodeProvider);
          requested = true;
        },
        settings: () async {
          settings = true;
        },
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(
          kKeepNodeBackgroundPrefKey,
        ),
        isNull,
      );
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      await done();
      expect(enableError, isNull);
      expect(persistedAtRequest, isTrue);
      expect(stateAtRequest, isTrue);
      expect(requested, isTrue);
      expect(settings, isFalse);
    },
  );

  testWidgets('OS request waits for enabling; dismissing cannot enable twice', (
    tester,
  ) async {
    final enabled = Completer<void>();
    var calls = 0;
    var requested = false;
    final done = await mountOffer(
      tester,
      enable: () {
        calls++;
        return enabled.future;
      },
      request: () async {
        requested = true;
      },
      settings: () async {},
    );
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(requested, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    enabled.complete();
    await tester.pumpAndSettle();
    await done();
    expect(requested, isTrue);
    expect(calls, 1);
  });

  for (final action in ['Later', "Don't ask again", 'App settings']) {
    testWidgets('$action never opts into the background service', (
      tester,
    ) async {
      var enabled = false;
      var requested = false;
      var settings = false;
      final done = await mountOffer(
        tester,
        enable: () async {
          enabled = true;
        },
        request: () async {
          requested = true;
        },
        settings: () async {
          settings = true;
        },
      );
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      await done();
      expect(enabled, isFalse);
      expect(requested, isFalse);
      expect(settings, action == 'App settings');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kKeepNodeBackgroundPrefKey), isNull);
      expect(await backgroundOfferSuppressed(), action == "Don't ask again");
    });
  }

  testWidgets('barrier dismissal does not change either choice', (
    tester,
  ) async {
    var called = false;
    final done = await mountOffer(
      tester,
      enable: () async {
        called = true;
      },
      request: () async {
        called = true;
      },
      settings: () async {
        called = true;
      },
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await done();
    expect(called, isFalse);
    expect(await backgroundOfferSuppressed(), isFalse);
  });

  testWidgets(
    'a failed start surfaces a fixed message without exception data',
    (tester) async {
      var requested = false;
      final done = await mountOffer(
        tester,
        enable: () async {
          throw StateError('private-path-and-identity');
        },
        request: () async {
          requested = true;
        },
        settings: () async {},
      );
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      await done();
      expect(requested, isFalse);
      expect(find.textContaining('private-path-and-identity'), findsNothing);
      expect(
        find.text(
          'Could not finish setting up background operation. '
          'Check it in the network settings.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
