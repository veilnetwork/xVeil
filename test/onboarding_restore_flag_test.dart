// Which flag the WIZARD hands the controller.
//
// `restoringIdentity` decides whether this device takes the phrase's own
// keypair as its node key or mints one of its own. Get it wrong on the restore
// path and two devices of one identity are literally one node: linking answers
// "self device", both drive the same ratchets, and the seeds see one identity
// with two sessions. That is the defect these tests stand guard over.
//
// The assertion is on what the SCREEN PASSES, not on what the controller keeps.
// `takePendingRestoringIdentity` is consuming — by the time a test could read
// it the boot may already have taken it, and an assertion that reads false on
// both paths passes while proving nothing.
//
// The controller's own half (what it does with a true flag) is covered by
// restored_device_key_test.dart and the live suite. This is the wiring between
// them, which nothing else touches.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/domain/identity.dart' show StorageMode;
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/onboarding_walk.dart';

/// No timers: FakeNodeController's delayed/periodic ones leak past a widget
/// test.
class _NoopNode implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

/// Records the call and then behaves exactly as the real controller does —
/// the wizard must still reach ready, or a test could "pass" on a screen that
/// never finished.
class _SpyController extends AppController {
  static bool? seenRestoring;
  static Uint8List? seenCredential;

  @override
  Future<void> completeOnboarding({
    required String password,
    required StorageMode mode,
    String? displayName,
    String? identityPhrase,
    bool restoringIdentity = false,
    bool joinExisting = false,
    bool recoveryCertificateOffered = false,
    bool recoveryCertificateSaved = false,
    Uint8List? sovereignCredential,
    String? nodeConfigToml,
  }) {
    seenRestoring = restoringIdentity;
    seenCredential = sovereignCredential;
    return super.completeOnboarding(
      password: password,
      mode: mode,
      displayName: displayName,
      identityPhrase: identityPhrase,
      restoringIdentity: restoringIdentity,
      joinExisting: joinExisting,
      recoveryCertificateOffered: recoveryCertificateOffered,
      recoveryCertificateSaved: recoveryCertificateSaved,
      sovereignCredential: sovereignCredential,
      nodeConfigToml: nodeConfigToml,
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _SpyController.seenRestoring = null;
    _SpyController.seenCredential = null;
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nodeControllerProvider.overrideWithValue(_NoopNode()),
          appControllerProvider.overrideWith(_SpyController.new),
        ],
        child: Consumer(
          builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: OnboardingScreen(
                mintIdentity: fakeMintedIdentity,
                saveCertificate: fakeSaveCertificate,
                // The restore path's code check is FFI; here any code opens
                // the certificate that was pasted.
                restoreCheck: (certificate, code) async => true,
                // The real validator is FFI; any 24 words pass here.
                validatePhrase: (p) => p.split(' ').length == 24,
                // And the real generator is FFI too. Named, because the screen
                // refuses to create an identity without a phrase now — the
                // substitute it used to fall back on is gone.
                generatePhrase: () =>
                    List.generate(24, (i) => 'word${i + 1}').join(' '),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  AppL10n l(WidgetTester tester) =>
      AppL10n.of(tester.element(find.byType(OnboardingScreen)));

  Future<void> finish(WidgetTester tester) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'test123');
    await tester.enterText(fields.at(1), 'test123');
    await tester.tap(find.text(l(tester).actionDone));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('creating an identity is not a restore', (tester) async {
    final container = await pump(tester);
    await tester.tap(find.text(l(tester).actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l(tester).onboardCreateIdentity));
    await tester.pumpAndSettle();
    await confirmRecoveryPhrase(
      tester,
      continueLabel: l(tester).actionContinue,
    );
    // storage, then network entry.
    await tester.tap(find.text(l(tester).actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l(tester).actionContinue));
    await tester.pumpAndSettle();
    await finish(tester);

    expect(container.read(appControllerProvider).phase, AppPhase.ready);
    // False, not null: null would mean the wizard never called through, and
    // then the flag below proves nothing.
    expect(_SpyController.seenRestoring, isFalse);
  });


  testWidgets('backing out of a restore does not create with its certificate', (
    tester,
  ) async {
    // Create and restore share this screen's State, and Back is ordinary
    // navigation. A certificate accepted on the restore path stayed in the
    // fields, and `_finish` preferred it over the one the create ceremony had
    // just minted and shown — so the person saved a backup for an identity
    // this install does not have (report27 X18).
    final container = await pump(tester);
    await tester.tap(find.text(l(tester).actionContinue));
    await tester.pumpAndSettle();

    // Restore: paste somebody else's certificate, prove the code.
    await tester.tap(find.text(l(tester).onboardRestoreIdentity));
    await tester.pumpAndSettle();
    final restored = Uint8List.fromList([
      ...ascii.encode('XVRC'),
      1,
      0,
      ...List<int>.filled(58, 0xCD),
    ]);
    final pasted =
        'xveil-recovery:v1:${base64Url.encode(restored).replaceAll('=', '')}';
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), pasted);
    await tester.enterText(fields.at(1), 'xvrc-a-code-longer-than-thirty-two-bytes');
    await tester.pumpAndSettle();
    await tester.tap(find.text(l(tester).onboardRestoreCertificateSubmit));
    await tester.pumpAndSettle();

    // Change your mind: back to the choice, and create instead. The wizard's
    // Back is its own control (the steps are not routes), and from the
    // password step it goes 3 → 8 → choice.
    for (var i = 0; i < 4; i++) {
      if (find.text(l(tester).onboardCreateIdentity).evaluate().isNotEmpty) {
        break;
      }
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(l(tester).onboardCreateIdentity));
    await tester.pumpAndSettle();
    await confirmRecoveryPhrase(
      tester,
      continueLabel: l(tester).actionContinue,
    );
    await tester.tap(find.text(l(tester).actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l(tester).actionContinue));
    await tester.pumpAndSettle();
    await finish(tester);

    expect(container.read(appControllerProvider).phase, AppPhase.ready);
    expect(
      _SpyController.seenRestoring,
      isFalse,
      reason: 'this is a create, whatever the restore path collected before',
    );
    expect(
      _SpyController.seenCredential,
      isNot(restored),
      reason:
          'the container was given the certificate the person abandoned, so '
          'the one the ceremony showed and saved backs up nothing',
    );
    expect(_SpyController.seenCredential, fakeMintedIdentity().credential);
  });
}
