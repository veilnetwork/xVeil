import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Switch the restore step onto the 24-word branch.
///
/// The step opens on the CERTIFICATE, deliberately: the words alone restore a
/// different identity, so someone holding their certificate must not have to
/// find it behind a toggle. A walk that means to type words therefore says so,
/// the way a person does.
///
/// Tolerant of the segment being absent, so the helper still serves a build
/// whose restore step has only one way in.
Future<void> chooseRestoreByPhrase(WidgetTester tester) async {
  final words = find.text(AppL10nEn().onboardRestoreWithPhrase);
  if (words.evaluate().isEmpty) return;
  await tester.ensureVisible(words);
  await tester.pumpAndSettle();
  await tester.tap(words);
  await tester.pumpAndSettle();
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
