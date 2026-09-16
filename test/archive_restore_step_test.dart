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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xveil/features/onboarding/archive_restore_step.dart';
import 'package:xveil/features/onboarding/credential_check.dart';
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
    void Function(String, Uint8List?, String)? onIdentity,
    CredentialSecretCheck? check,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: Scaffold(
      body: ArchiveRestoreStep(
        open: open,
        onIdentity: onIdentity ?? (_, _, _) {},
        check: check ?? (_, _) async => true,
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
        open: ({required password, reuseLast = false}) async => _withIdentity(),
        onIdentity: (toml, _, _) => got = toml,
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
    await tester.pumpWidget(host(open: ({required password, reuseLast = false}) async => null));
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
        open: ({required password, reuseLast = false}) async => const ArchivePreview(
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
      host(open: ({required password, reuseLast = false}) async => throw const FormatException()),
    );
    await tester.pumpAndSettle();
    await pick(tester);
    expect(find.text(AppL10nEn().onboardArchiveBad), findsOneWidget);
  });

  testWidgets('the refusal says WHY, not just that it was refused', (
    tester,
  ) async {
    // Reported from the field: an archive this app's own reader opens
    // correctly — header parsed, identity extracted — was refused here as
    // "damaged", and "damaged" was the only thing anyone could see. One
    // opaque sentence is the difference between a defect somebody can find
    // and a person concluding their backup is ruined.
    await tester.pumpWidget(
      host(
        open: ({required password, reuseLast = false}) async =>
            throw const FileSystemException('operation not permitted', '/x'),
      ),
    );
    await tester.pumpAndSettle();
    await pick(tester);

    expect(find.text(AppL10nEn().onboardArchiveBad), findsOneWidget);
    expect(
      find.textContaining('operation not permitted'),
      findsOneWidget,
      reason: 'the reason is what makes the report actionable',
    );
  });

  testWidgets('a sealed archive asks for its password rather than blaming the file', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(open: ({required password, reuseLast = false}) async => _withIdentity(sealed: true)),
    );
    await tester.pumpAndSettle();
    await pick(tester);
    // Not "damaged": the difference between someone typing their password and
    // someone concluding their backup is ruined. And the box appears only NOW,
    // for the archive that turned out to have one — everyone else is never
    // asked.
    expect(find.text(AppL10nEn().onboardArchiveUnlock), findsOneWidget);
    expect(find.text(AppL10nEn().onboardArchiveBad), findsNothing);
  });


  testWidgets('an archive with no password is never asked for one', (
    tester,
  ) async {
    // The other half, and the one that was reported: the box used to stand
    // above the picker and be put to everyone, including the majority whose
    // archive is not sealed.
    await tester.pumpWidget(
      host(open: ({required password, reuseLast = false}) async => _withIdentity()),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(AppL10nEn().onboardArchivePasswordLabel),
      findsNothing,
      reason: 'nothing has been chosen yet, so there is nothing to unlock',
    );
    await pick(tester);
    expect(find.text(AppL10nEn().onboardArchivePasswordLabel), findsNothing);
    expect(find.text(AppL10nEn().onboardArchiveUnlock), findsNothing);
  });

  group('an archive that carries the identity key', () {
    // The third place the same root defect surfaced: the export wrote the node
    // config and called it the identity. The address a person's contacts hold
    // comes from the hybrid master, whose Falcon half is reproducible from
    // nothing — so an archive without it restored a device that talks on the
    // right wire key and answers where nobody writes. Reported as
    // "восстановилась другая личность (другой node_id)".
    final credential = Uint8List.fromList(
      ascii.encode('XVSB') + List<int>.filled(60, 7),
    );

    ArchivePreview withCredential() => ArchivePreview(
      nodeIdHex: 'ab' * 32,
      createdMs: 1700000000000,
      includesIdentity: true,
      sealed: false,
      identityToml: _toml,
      credential: credential,
    );

    Future<void> typeSecret(WidgetTester tester, String secret) async {
      final field = find.byType(TextField).last;
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, secret);
      await tester.pumpAndSettle();
    }

    testWidgets('the credential leaves the step with its config', (
      tester,
    ) async {
      Uint8List? gotCredential;
      String? gotSecret;
      await tester.pumpWidget(
        host(
          open: ({required password, reuseLast = false}) async => withCredential(),
          onIdentity: (_, c, secret) {
            gotCredential = c;
            gotSecret = secret;
          },
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      await typeSecret(tester, 'twenty four words go here');

      final go = find.text(AppL10nEn().onboardArchiveContinue);
      await tester.ensureVisible(go);
      await tester.pumpAndSettle();
      await tester.tap(go);
      await tester.pumpAndSettle();

      expect(gotCredential, credential);
      expect(gotSecret, 'twenty four words go here');
    });

    testWidgets('nothing is taken until the secret is given', (tester) async {
      await tester.pumpWidget(
        host(open: ({required password, reuseLast = false}) async => withCredential()),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
        reason:
            'taking the config without the credential is the half-restore this '
            'step exists to stop',
      );
    });

    /// The phrase is normalized here as it is everywhere else it is typed.
    ///
    /// Every other entry point folds case and runs the words together on
    /// single spaces before the byte-based KDF sees them; this one only
    /// trimmed the ends. So the same twenty-four words, typed with the line
    /// break they were written down with or the capitals a keyboard puts on
    /// them, hashed to different bytes and were refused on a perfectly good
    /// archive — with the message reserved for a WRONG secret, which is the
    /// one thing a person cannot debug (report27 X20).
    testWidgets('the words open it however they were typed', (tester) async {
      String? seen;
      var taken = false;
      await tester.pumpWidget(
        host(
          open: ({required password, reuseLast = false}) async =>
              withCredential(),
          onIdentity: (_, _, _) => taken = true,
          check: (_, secret) async {
            seen = secret;
            return secret == 'alpha bravo charlie delta';
          },
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      await typeSecret(tester, '  Alpha  BRAVO\n charlie\tDelta  ');
      await tester.tap(find.text(AppL10nEn().onboardArchiveContinue));
      await tester.pumpAndSettle();

      expect(
        seen,
        'alpha bravo charlie delta',
        reason:
            'the credential was asked to open with $seen — the same words, '
            'and a different byte string than every other screen sends',
      );
      expect(taken, isTrue, reason: 'a good archive was refused');
    });

    testWidgets('a secret that does not open it takes nothing', (tester) async {
      var taken = false;
      await tester.pumpWidget(
        host(
          open: ({required password, reuseLast = false}) async => withCredential(),
          onIdentity: (_, _, _) => taken = true,
          check: (_, secret) async => secret == 'the right one',
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      await typeSecret(tester, 'not the right one');
      await tester.tap(find.text(AppL10nEn().onboardArchiveContinue));
      await tester.pumpAndSettle();

      expect(taken, isFalse);
      expect(find.text(AppL10nEn().onboardRestoreCodeRefused), findsOneWidget);
    });

    testWidgets('an archive from before the credential says so, loudly', (
      tester,
    ) async {
      // Taking it is allowed — the conversations are real. Taking it in
      // silence is not: that is the failure the credential record exists for,
      // arriving again through the one file that cannot carry the fix.
      await tester.pumpWidget(
        host(open: ({required password, reuseLast = false}) async => _withIdentity()),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      expect(
        find.text(AppL10nEn().onboardArchiveNoCredential),
        findsOneWidget,
      );
    });

    testWidgets('a current archive does not carry that warning', (
      tester,
    ) async {
      // The control: a warning shown on every archive would be noise, and
      // noise is not a warning.
      await tester.pumpWidget(
        host(open: ({required password, reuseLast = false}) async => withCredential()),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      expect(find.text(AppL10nEn().onboardArchiveNoCredential), findsNothing);
    });

    testWidgets('an archive with no credential is still taken', (tester) async {
      // The control, and a real case: every archive written before the
      // exporter carried a credential. It restores the transport key, which is
      // what it has, and the ceremony must not refuse it for missing what it
      // never held.
      var taken = false;
      await tester.pumpWidget(
        host(
          open: ({required password, reuseLast = false}) async => _withIdentity(),
          onIdentity: (_, c, _) => taken = c == null,
        ),
      );
      await tester.pumpAndSettle();
      await pick(tester);
      final go = find.text(AppL10nEn().onboardArchiveContinue);
      await tester.ensureVisible(go);
      await tester.pumpAndSettle();
      await tester.tap(go);
      await tester.pumpAndSettle();
      expect(taken, isTrue);
    });
  });
}
