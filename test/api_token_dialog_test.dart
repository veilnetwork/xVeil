// The add-token dialog's read-only switch, and what it says it refuses.
//
// The switch said "Read-only" and nothing else, leaving the reader to guess
// whether that stops a bot sending messages or only stops it changing
// settings. The string that answers it — `settingsApiReadOnlyHint` — was
// written into both ARBs and then attached to nothing, which is the mistake
// the reachability gate exists to catch: a translated orphan looks exactly
// like a translated string.
//
// The second test is the other half of the same job. A label that fits in
// English is not a label: Russian runs 61 characters against English's 56 and
// Spanish 68, and a subtitle in a narrow dialog is where that shows up. A
// Flutter overflow is an exception, so pumping each locale and settling IS the
// check — there is nothing to assert beyond the absence of one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/features/settings/privacy_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

Future<HiddenVolumeStorage> _storage() async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  return storage;
}

Future<AppL10n> _openAddTokenDialog(WidgetTester tester, Locale locale) async {
  ApiServerController.debugBindPort = 0;
  addTearDown(() => ApiServerController.debugBindPort = kApiPort);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [storageProvider.overrideWithValue(await _storage())],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const PrivacySettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final l = AppL10n.of(tester.element(find.byType(PrivacySettingsScreen)));

  // The token list only exists once the API is on, and the settings screen is
  // longer than the test viewport — scroll to each control before touching it.
  //
  // The TILE is the tap target, never its label. A Text inside a scrolled
  // ListTile resolves to a point the hit test does not land on, and `tap` only
  // WARNS about that — so the tap silently does nothing. It happened to land in
  // English and missed in Spanish, where the longer title wraps and moves the
  // centre: a test that passes in one language and not another, for a reason
  // that has nothing to do with the language.
  final apiSwitch = find.ancestor(
    of: find.text(l.settingsApiTitle),
    matching: find.byType(SwitchListTile),
  );
  await tester.scrollUntilVisible(apiSwitch, 200);
  await tester.ensureVisible(apiSwitch);
  await tester.pumpAndSettle();
  await tester.tap(apiSwitch);
  await tester.pumpAndSettle();

  final addToken = find.ancestor(
    of: find.text(l.settingsApiAddToken),
    matching: find.byType(ListTile),
  );
  await tester.scrollUntilVisible(addToken, 200);
  await tester.ensureVisible(addToken);
  await tester.pumpAndSettle();
  await tester.tap(addToken);
  await tester.pumpAndSettle();
  return l;
}

void main() {
  testWidgets('the read-only switch says what it refuses', (tester) async {
    final l = await _openAddTokenDialog(tester, const Locale('en'));

    expect(
      find.text(l.settingsApiReadOnly),
      findsOneWidget,
      reason: 'the read-only switch is not in the add-token dialog',
    );
    expect(
      find.text(l.settingsApiReadOnlyHint),
      findsOneWidget,
      reason:
          'the switch offers a restriction without saying what it restricts — '
          'a token handed to a bot on that basis is a guess',
    );
  });

  // One test per locale, not one loop: re-mounting a fresh ProviderScope
  // inside a single test leaves the previous route behind and the second
  // pass finds nothing to scroll.
  for (final locale in AppL10n.supportedLocales) {
    testWidgets('the dialog fits in ${locale.languageCode}', (tester) async {
      final l = await _openAddTokenDialog(tester, locale);
      expect(
        find.text(l.settingsApiReadOnlyHint),
        findsOneWidget,
        reason: 'the hint is missing in ${locale.languageCode}',
      );
      // Reaching here without an exception is the assertion: an overflowing
      // subtitle throws during layout, and pumpAndSettle rethrows it.
    });
  }
}
