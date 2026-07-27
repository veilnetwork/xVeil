import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/features/settings/settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

/// The profile switcher is deliberately hidden: someone with no reason to run
/// two installations should never meet a screen offering to split their data.
/// These pin the gesture that reveals it and, just as importantly, that a
/// casual tap does not.
Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: SettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('hidden until revealed', (tester) async {
    await _pump(tester);
    expect(find.text('Profiles'), findsNothing);
  });

  testWidgets('three taps on the title reveal it, and the reveal persists', (
    tester,
  ) async {
    await _pump(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Settings'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('Profiles'), findsOneWidget);

    // Remembered, so it is a one-time gesture rather than a password.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppProfiles.revealedPref), isTrue);
  });

  testWidgets('two taps do not reveal, and the count decays', (tester) async {
    await _pump(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Settings'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('Profiles'), findsNothing);

    // A stray tap now and another next week must not add up to a reveal.
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Profiles'), findsNothing);
  });

  testWidgets('a remembered reveal shows the entry on first build', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({AppProfiles.revealedPref: true});
    await _pump(tester);
    expect(find.text('Profiles'), findsOneWidget);
  });
}
