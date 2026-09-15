// Handing the app a recovery certificate before it has an identity.
//
// Reported from the field: "при восстановлении из фразы некуда применять
// сертификат — то есть сейчас личность не восстановить". That was true. The
// certificate could only be given to the app from Settings → Devices, which
// needs an identity to open, and by then the node had booted under the classic
// identity the words produce — a DIFFERENT one, at an address none of the
// person's contacts hold.
//
// The boot path always had the right entry
// (`provisionIdentityFromCertificate`, opened by the CODE rather than the
// words); what was missing was a way to reach it. These tests hold the reach.
//
// AND THE SECOND REPORT, which is what the last group here is for: "код
// восстановления могу ввести любой (первый раз ввел фразу и получил другую
// личность)". Nothing on this screen opened the certificate, so any non-empty
// string walked through; the wrong one then failed deep in the boot, where the
// failure was swallowed, and the install came up at a brand new address
// without a word. A screen that asks for a secret and never checks it is not
// asking for a secret.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/onboarding/certificate_restore_input.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';

/// The smallest thing `SovereignRecoveryCertificate.fromBytes` accepts: the
/// XVRC magic, version 1, and a 32-byte node id at offset 6.
Uint8List _certificateBytes(int fill) {
  final bytes = Uint8List(38);
  bytes.setAll(0, ascii.encode('XVRC'));
  bytes[4] = 1;
  bytes[5] = 0;
  for (var i = 6; i < 38; i++) {
    bytes[i] = fill;
  }
  return bytes;
}

String _certificateText(int fill) =>
    'xveil-recovery:v1:${base64Url.encode(_certificateBytes(fill)).replaceAll('=', '')}';

void main() {
  // No real file is written and none is read. Real IO inside `testWidgets`
  // does not fail, it HANGS: stream events are never delivered in fake time
  // and `pumpAndSettle` waits ten minutes before reporting something that has
  // nothing to do with the widget. The picker hands over contents, so the test
  // hands over a string.
  //
  // The code check is injected for the same reason in reverse: the real one is
  // Argon2id over a native handle, and a widget test that skipped it would be
  // asserting away the thing this screen exists to do.
  Widget host({
    required void Function(Uint8List, String) onSubmit,
    Future<String?> Function()? pick,
    RecoveryCodeCheck? check,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: Scaffold(
      body: CertificateRestoreInput(
        onSubmit: onSubmit,
        pick: pick ?? () async => null,
        check: check ?? (_, _) async => true,
      ),
    ),
  );

  Future<void> typeCode(WidgetTester tester, String code) async {
    await tester.enterText(
      find.widgetWithText(TextField, AppL10nEn().onboardRestoreCodeLabel),
      code,
    );
    await tester.pumpAndSettle();
  }

  Future<void> paste(WidgetTester tester, String text) async {
    await tester.enterText(
      find.widgetWithText(
        TextField,
        AppL10nEn().onboardRestorePasteCertificate,
      ),
      text,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a certificate and its code are handed over together', (
    tester,
  ) async {
    Uint8List? gotCertificate;
    String? gotCode;
    await tester.pumpWidget(
      host(
        onSubmit: (c, code) {
          gotCertificate = c;
          gotCode = code;
        },
        pick: () async => _certificateText(0xAB),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10nEn();
    // Nothing can be submitted before both halves are in hand: the file alone
    // is a locked box, and the code alone opens nothing.
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.tap(find.text(l.onboardRestorePickCertificate));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'the code is the other half and has not been typed',
    );

    await typeCode(tester, 'xvrc-Aa09_TESTCODE');
    await tester.tap(find.text(l.onboardRestoreCertificateSubmit));
    await tester.pumpAndSettle();

    expect(gotCertificate, isNotNull);
    expect(gotCertificate!.length, 38);
    expect(
      gotCode,
      'xvrc-Aa09_TESTCODE',
      reason: 'the code is base64url; folding its case destroys it',
    );
  });

  testWidgets('the chosen certificate names the address it restores', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(onSubmit: (_, _) {}, pick: () async => _certificateText(0xAB)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppL10nEn().onboardRestorePickCertificate));
    await tester.pumpAndSettle();

    // Someone holding two certificates has to be able to tell which one this
    // is before committing the whole install to it.
    expect(find.textContaining('abababababababab'), findsOneWidget);
  });

  testWidgets('a file that is not a certificate is refused, not accepted', (
    tester,
  ) async {
    var submitted = false;
    await tester.pumpWidget(
      host(
        onSubmit: (_, _) => submitted = true,
        pick: () async => 'my 24 words are elsewhere',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppL10nEn().onboardRestorePickCertificate));
    await tester.pumpAndSettle();

    expect(find.text(AppL10nEn().onboardRestoreCertificateBad), findsOneWidget);
    await typeCode(tester, 'xvrc-anything');
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'a refused file must not become a restorable identity',
    );
    expect(submitted, isFalse);
  });

  testWidgets('choosing nothing changes nothing', (tester) async {
    await tester.pumpWidget(host(onSubmit: (_, _) {}, pick: () async => null));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppL10nEn().onboardRestorePickCertificate));
    await tester.pumpAndSettle();
    expect(find.text(AppL10nEn().onboardRestoreCertificateBad), findsNothing);
  });

  group('a certificate that was copied, not downloaded', () {
    // The export sheet offers a copy button beside the save button, so a
    // copied certificate is as ordinary as a saved one — and a copy comes back
    // through whatever carried it.
    testWidgets('a pasted certificate is the same certificate', (tester) async {
      Uint8List? got;
      await tester.pumpWidget(
        host(onSubmit: (c, _) => got = c),
      );
      await tester.pumpAndSettle();
      await paste(tester, _certificateText(0xCD));
      expect(find.textContaining('cdcdcdcdcdcdcdcd'), findsOneWidget);

      await typeCode(tester, 'xvrc-code');
      await tester.tap(find.text(AppL10nEn().onboardRestoreCertificateSubmit));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect(got!.length, 38);
    });

    testWidgets('a paste that came through a chat still identifies itself', (
      tester,
    ) async {
      await tester.pumpWidget(host(onSubmit: (_, _) {}));
      await tester.pumpAndSettle();
      // Wrapped across lines, with a label in front — how a copy actually
      // comes back out of a note or a message.
      final wrapped = _certificateText(0xCD);
      await paste(
        tester,
        'my xVeil certificate:\n'
        '${wrapped.substring(0, 30)}\n${wrapped.substring(30)}\n',
      );
      expect(find.text(AppL10nEn().onboardRestoreCertificateBad), findsNothing);
      expect(find.textContaining('cdcdcdcdcdcdcdcd'), findsOneWidget);
    });

    testWidgets('pasted prose is still refused', (tester) async {
      await tester.pumpWidget(host(onSubmit: (_, _) {}));
      await tester.pumpAndSettle();
      await paste(tester, 'here are my 24 words, I think');
      // The control for the two above: tolerance about packaging must not
      // become tolerance about content.
      expect(
        find.text(AppL10nEn().onboardRestoreCertificateBad),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });
  });

  group('the code is checked against the certificate', () {
    testWidgets('a code that does not open it submits nothing', (tester) async {
      var submitted = false;
      await tester.pumpWidget(
        host(
          onSubmit: (_, _) => submitted = true,
          pick: () async => _certificateText(0xAB),
          // What the field report did: the 24 words typed where the code goes.
          check: (_, code) async => code.startsWith('xvrc-'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppL10nEn().onboardRestorePickCertificate));
      await tester.pumpAndSettle();
      await typeCode(tester, 'abandon abandon abandon abandon abandon');
      await tester.tap(find.text(AppL10nEn().onboardRestoreCertificateSubmit));
      await tester.pumpAndSettle();

      expect(
        submitted,
        isFalse,
        reason:
            'letting a refused code through mints a device key and comes up '
            'at an address nobody holds — the failure the report describes',
      );
      expect(find.text(AppL10nEn().onboardRestoreCodeRefused), findsOneWidget);
    });

    testWidgets('the right code still goes through', (tester) async {
      // The vacuity guard. Without it the assertion above would pass just as
      // well over a screen that had stopped submitting anything at all.
      var submitted = false;
      await tester.pumpWidget(
        host(
          onSubmit: (_, _) => submitted = true,
          pick: () async => _certificateText(0xAB),
          check: (_, code) async => code.startsWith('xvrc-'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppL10nEn().onboardRestorePickCertificate));
      await tester.pumpAndSettle();
      await typeCode(tester, 'xvrc-the-real-one');
      await tester.tap(find.text(AppL10nEn().onboardRestoreCertificateSubmit));
      await tester.pumpAndSettle();

      expect(submitted, isTrue);
      expect(find.text(AppL10nEn().onboardRestoreCodeRefused), findsNothing);
    });

    testWidgets('the refusal clears when the code is retyped', (tester) async {
      await tester.pumpWidget(
        host(
          onSubmit: (_, _) {},
          pick: () async => _certificateText(0xAB),
          check: (_, code) async => code.startsWith('xvrc-'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppL10nEn().onboardRestorePickCertificate));
      await tester.pumpAndSettle();
      await typeCode(tester, 'wrong');
      await tester.tap(find.text(AppL10nEn().onboardRestoreCertificateSubmit));
      await tester.pumpAndSettle();
      expect(find.text(AppL10nEn().onboardRestoreCodeRefused), findsOneWidget);

      // A message that stays on screen while the person fixes the thing it is
      // about reads as "still wrong", and they stop.
      await typeCode(tester, 'xvrc-second-try');
      expect(find.text(AppL10nEn().onboardRestoreCodeRefused), findsNothing);
    });
  });
}
