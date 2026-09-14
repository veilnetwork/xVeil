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
  Widget host({
    required void Function(Uint8List, String) onSubmit,
    required Future<String?> Function() pick,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: Scaffold(
      body: CertificateRestoreInput(onSubmit: onSubmit, pick: pick),
    ),
  );

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

    await tester.enterText(find.byType(TextField), 'xvrc-Aa09_TESTCODE');
    await tester.pumpAndSettle();
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
    await tester.enterText(find.byType(TextField), 'xvrc-anything');
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'a refused file must not become a restorable identity',
    );
    expect(submitted, isFalse);
  });

  testWidgets('choosing nothing changes nothing', (tester) async {
    await tester.pumpWidget(
      host(onSubmit: (_, _) {}, pick: () async => null),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppL10nEn().onboardRestorePickCertificate));
    await tester.pumpAndSettle();
    expect(find.text(AppL10nEn().onboardRestoreCertificateBad), findsNothing);
  });
}
