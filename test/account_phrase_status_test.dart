import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/features/settings/account_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

/// The honest recovery-phrase status tile in Settings → Account (phrase epic
/// P4): 'phrase' shows the restorable hint, 'mined' and null (legacy space
/// without the marker) both show the created-without-a-phrase hint.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppL10n> pump(WidgetTester tester, String? origin) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        identityOriginProvider.overrideWith((ref) async => origin),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const AccountSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    return AppL10n.of(tester.element(find.byType(AccountSettingsScreen)));
  }

  testWidgets('phrase-derived identity shows the restorable status',
      (tester) async {
    final l = await pump(tester, 'phrase');
    expect(find.text(l.settingsPhraseStatusTitle), findsOneWidget);
    expect(find.text(l.settingsPhraseBackedHint), findsOneWidget);
    expect(find.text(l.settingsPhraseNoneHint), findsNothing);
  });

  testWidgets('mined identity is honestly marked as phrase-less',
      (tester) async {
    final l = await pump(tester, 'mined');
    expect(find.text(l.settingsPhraseNoneHint), findsOneWidget);
    expect(find.text(l.settingsPhraseBackedHint), findsNothing);
  });

  testWidgets('legacy space without the marker is honestly marked too',
      (tester) async {
    final l = await pump(tester, null);
    expect(find.text(l.settingsPhraseNoneHint), findsOneWidget);
    expect(find.text(l.settingsPhraseBackedHint), findsNothing);
  });
}
