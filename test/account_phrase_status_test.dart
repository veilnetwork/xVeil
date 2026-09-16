// What Settings → Account says brings this identity back.
//
// The row used to read the config's ORIGIN alone — "was this derived from a
// phrase" — and say "created without a recovery phrase, protect your data by
// other means" for anything else. Since creating an identity stopped handing
// out words that is every new identity, and the sentence is wrong twice over:
// it announces an absence where a recovery certificate exists, and tells the
// person to improvise a backup while they are holding one. Asked from the
// field: "зачем теперь эта информация? она как будто не особо уже нужна".
//
// Four states now, and the credential decides three of them. Each is checked
// here because each is a different promise to a person who cannot verify it
// for themselves.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/settings/account_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppL10n> pump(
    WidgetTester tester,
    ({IdentityRecoveryState state, bool saved})? recovery,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityRecoveryProvider.overrideWith((ref) async => recovery),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const AccountSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppL10n.of(tester.element(find.byType(AccountSettingsScreen)));
  }

  testWidgets('a certificate identity is told what brings it back', (
    tester,
  ) async {
    final l = await pump(tester, (
      state: IdentityRecoveryState.certificate,
      saved: true,
    ));
    expect(find.text(l.settingsRecoveryTitle), findsOneWidget);
    expect(find.text(l.settingsRecoveryByCertificate), findsOneWidget);
    expect(
      find.text(l.settingsRecoveryNothing),
      findsNothing,
      reason: 'an identity with a certificate is not one nothing can restore',
    );
  });

  testWidgets('a certificate with no copy saved says so', (tester) async {
    final l = await pump(tester, (
      state: IdentityRecoveryState.certificate,
      saved: false,
    ));
    expect(
      find.textContaining(l.settingsRecoveryCertificateMissing),
      findsOneWidget,
      reason:
          'until a copy exists the identity is one device failure from gone, '
          'and that is the one thing worth interrupting for',
    );
  });

  testWidgets('a phrase-wrapped credential is not called a backup', (
    tester,
  ) async {
    // The state that used to read as reassuring: the words open the credential,
    // so the old row said "your phrase restores it". It does not — half the
    // key exists only inside this device.
    final l = await pump(tester, (
      state: IdentityRecoveryState.bundleNoCopy,
      saved: false,
    ));
    expect(find.text(l.settingsRecoveryBundleNoCopy), findsOneWidget);
  });

  testWidgets('a classic identity IS restored by its words, and is told so', (
    tester,
  ) async {
    // The one case where words are the whole answer, and the row must not
    // frighten those people into thinking otherwise.
    final l = await pump(tester, (
      state: IdentityRecoveryState.phraseOnly,
      saved: false,
    ));
    expect(find.text(l.settingsRecoveryPhraseOnly), findsOneWidget);
  });

  testWidgets('an identity nothing restores is told plainly', (tester) async {
    final l = await pump(tester, (
      state: IdentityRecoveryState.nothing,
      saved: false,
    ));
    expect(find.text(l.settingsRecoveryNothing), findsOneWidget);
  });

  testWidgets('an unreadable answer shows no row at all', (tester) async {
    // A wrong claim about the one thing a person cannot check for themselves
    // is worse than silence.
    final l = await pump(tester, null);
    expect(find.text(l.settingsRecoveryTitle), findsNothing);
  });
}
