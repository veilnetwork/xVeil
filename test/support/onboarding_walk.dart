import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/features/onboarding/recovery_certificate_step.dart';
import 'package:xveil/l10n/app_localizations_en.dart';

/// Tick "I have written down all 24 words" and move on.
///
/// The confirmation and the Continue button live BELOW word 24 inside the
/// recovery step's own scroll, which is the fix for a phone that could not
/// put all 24 words on screen: a person cannot claim the backup is done
/// without the last word having passed under their finger. That makes the
/// controls reachable rather than pinned, so a walk through the wizard has to
/// scroll to them the way a person does — hence [WidgetTester.ensureVisible]
/// rather than a bare tap.
///
/// Kept here instead of copied into each suite so that the next change to the
/// step's layout breaks in ONE place with this comment attached, rather than
/// in six with none. The gate on the layout itself is
/// test/recovery_phrase_layout_test.dart.
Future<void> confirmRecoveryPhrase(
  WidgetTester tester, {
  required String continueLabel,
}) async {
  // WHICHEVER CEREMONY STANDS HERE. Creating an identity no longer shows the
  // 24 words — they never restored it — so a walk that came for the checkbox
  // finds a certificate instead. One helper crosses both, because what every
  // caller actually wants is "get from the choice to storage".
  if (find.byType(Checkbox).evaluate().isEmpty) {
    await saveRecoveryCertificate(tester);
    return;
  }
  await tester.ensureVisible(find.byType(Checkbox));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(Checkbox));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(continueLabel));
  await tester.pumpAndSettle();
  await tester.tap(find.text(continueLabel));
  await tester.pumpAndSettle();
  await declineRecoveryCertificate(tester);
}

/// Step past the recovery-certificate offer that now follows the phrase.
///
/// It follows the phrase because that is the only moment the app HOLDS the
/// words and can mint the certificate without asking for them back — which is
/// the whole point of the step. A walk through the wizard therefore has one
/// more screen to cross, and declining is the right way for a test to cross
/// it: taking the offer calls into the native library, which is not loaded in
/// the test host.
///
/// Tolerant of the step being absent so the helper still serves a build whose
/// phrase generator returned nothing — there is no certificate to offer for a
/// phrase that was never made.
Future<void> declineRecoveryCertificate(WidgetTester tester) async {
  final skip = find.text(AppL10nEn().onboardCertSkip);
  if (skip.evaluate().isEmpty) return;
  await tester.ensureVisible(skip);
  await tester.pumpAndSettle();
  await tester.tap(skip);
  await tester.pumpAndSettle();
}

/// Cross the create path's certificate step: save the file, then continue.
///
/// There is no declining here and no words behind it. Creating an identity
/// mints a credential whose only secret is its code, so leaving without the
/// file on disk would be creating an identity nothing can restore — the step
/// refuses, deliberately, and a walk has to save the way a person does.
///
/// Tolerant of the step being absent, so the helper still serves a path that
/// does not pass through it.
Future<void> saveRecoveryCertificate(WidgetTester tester) async {
  final save = find.text(AppL10nEn().devicesSaveCertificate);
  if (save.evaluate().isEmpty) return;
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
  final go = find.text(AppL10nEn().onboardCertContinue);
  await tester.ensureVisible(go);
  await tester.pumpAndSettle();
  await tester.tap(go);
  await tester.pumpAndSettle();
}

/// A mint the test host can actually run.
///
/// The real one makes a hybrid master and re-wraps it as a certificate: two
/// Argon2 passes through the native library, which `flutter test` does not
/// load. What a walk needs from it is shape, not cryptography — a credential
/// carrying the XVRC magic, a certificate text, a code, and a node id.
MintedRecovery fakeMintedIdentity() {
  final bytes = Uint8List(64);
  bytes.setAll(0, ascii.encode('XVRC'));
  bytes[4] = 1;
  for (var i = 6; i < 38; i++) {
    bytes[i] = 0xAB;
  }
  return MintedRecovery(
    credential: bytes,
    certificate:
        'xveil-recovery:v1:${base64Url.encode(bytes).replaceAll('=', '')}',
    code: 'xvrc-test-code-with-more-than-thirty-two-bytes',
    nodeId: NodeId(Uint8List.fromList(List<int>.filled(32, 0xAB))),
  );
}

/// A save that lands without touching a disk or a file dialog.
Future<bool> fakeSaveCertificate(String certificate, String name) async => true;
