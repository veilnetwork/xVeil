import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
