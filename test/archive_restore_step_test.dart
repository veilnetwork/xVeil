// The fourth way in: an archive that carries the identity.
//
// The export screen has always promised it — "a clean install becomes this
// device from one archive, without the recovery phrase" — and the app had no
// way to keep the promise. An identity-bearing archive applies only to a
// device holding no identity, which is true strictly before setup finishes;
// the importer lived only in Settings, which needs a finished setup to open.
// The person stood outside a closed circle, holding the file.
//
// This step does the half that must come first. The conversations cannot come
// with the identity — the appliers that merge them are registered by the group
// service, which needs a signer, which needs the identity — so the step says
// where the second half happens rather than pretending it already did.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/onboarding/archive_restore_step.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';

const _toml = '[identity]\nkey = "restored"';

ArchivePreview _withIdentity({bool sealed = false}) => ArchivePreview(
  nodeIdHex: 'ab' * 32,
  createdMs: 1700000000000,
  includesIdentity: true,
  sealed: sealed,
  identityToml: _toml,
);

void main() {
  Widget host({
    required ArchiveOpener open,
    void Function(String)? onIdentity,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: Scaffold(
      body: ArchiveRestoreStep(
        open: open,
        onIdentity: onIdentity ?? (_) {},
      ),
    ),
  );

  Future<void> pick(WidgetTester tester) async {
    final button = find.text(AppL10nEn().onboardArchivePick);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('the identity in the archive is what leaves this step', (
    tester,
  ) async {
    String? got;
    await tester.pumpWidget(
      host(
        open: ({required password}) async => _withIdentity(),
        onIdentity: (toml) => got = toml,
      ),
    );
    await tester.pumpAndSettle();
    await pick(tester);

    final go = find.text(AppL10nEn().onboardArchiveContinue);
    await tester.ensureVisible(go);
    await tester.pumpAndSettle();
    await tester.tap(go);
    await tester.pumpAndSettle();
    expect(got, _toml);
  });

  testWidgets('nothing can be taken before an archive is chosen', (
    tester,
  ) async {
    await tester.pumpWidget(host(open: ({required password}) async => null));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('an archive with no identity says which door to use instead', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        open: ({required password}) async => const ArchivePreview(
          nodeIdHex: 'cd',
          createdMs: 1700000000000,
          includesIdentity: false,
          sealed: false,
          identityToml: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await pick(tester);

    expect(find.text(AppL10nEn().onboardArchiveNoIdentity), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'an archive without an identity cannot decide who this device is',
    );
  });

  testWidgets('a file that will not read is reported, not swallowed', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(open: ({required password}) async => throw const FormatException()),
    );
    await tester.pumpAndSettle();
    await pick(tester);
    expect(find.text(AppL10nEn().onboardArchiveBad), findsOneWidget);
  });

  testWidgets('a sealed archive asks for its password rather than blaming the file', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(open: ({required password}) async => _withIdentity(sealed: true)),
    );
    await tester.pumpAndSettle();
    await pick(tester);
    // Not "damaged": the difference between someone typing their password and
    // someone concluding their backup is ruined.
    expect(find.text(AppL10nEn().transferImportPasswordTitle), findsOneWidget);
    expect(find.text(AppL10nEn().onboardArchiveBad), findsNothing);
  });
}
