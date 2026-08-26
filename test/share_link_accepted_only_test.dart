import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/expect_before.dart';

/// Sharing an entry point with a contact.
///
/// `MessagingCore.sendText` has a consent gate: it returns silently for a
/// contact that is not ACCEPTED. The sheet offered every contact that was not
/// blocked, so choosing a pending one closed the sheet and reported it sent —
/// when nothing had been (report16 XV-17).
///
/// Structural, and this is why: the sheet needs a live messaging service and a
/// conversation store to open at all, and what is being checked is which
/// contacts it puts in front of a person and what it asks before it claims
/// anything. Both are decisions in the source rather than behaviour a fake can
/// produce here.
void main() {
  final source = File(
    'lib/features/network/share_link_sheet.dart',
  ).readAsStringSync();

  test('only ACCEPTED contacts are offered', () {
    expect(
      source,
      contains('c.status == ContactStatus.accepted'),
      reason: 'a contact who cannot be sent to is offered as if they could',
    );
    expect(
      source,
      isNot(contains('c.status != ContactStatus.blocked')),
      reason:
          '"not blocked" includes pending, and a send to pending is a silent '
          'no-op that this sheet then calls sent',
    );
  });

  test('and the status is asked again before anything is sent', () {
    // The picker is built before it is shown, and a contact can be
    // un-accepted while it is open.
    expectBefore(
      source,
      'current.status != ContactStatus.accepted',
      'sendText(chosen.nodeId, uri)',
    );
  });

  test('and a refusal is shown IN the sheet, not after it closes', () {
    // The sheet is what the person is looking at; a snackbar raised from a
    // context `pop` has just removed goes nowhere. The success path takes the
    // messenger before popping for the same reason.
    final refusal = source.indexOf('oproxyShareNotAccepted');
    expect(refusal, isNot(-1), reason: 'nothing is said at all');
    expect(
      source.substring(refusal - 200, refusal),
      contains('_notice'),
      reason: 'the refusal is raised somewhere the person is not looking',
    );
  });

  test('the core still refuses on its own', () {
    // The sheet filtering is not the guarantee — it is the part that stops a
    // person being told a lie. The gate underneath must stay.
    final core = File('lib/state/messaging_core.dart').readAsStringSync();
    expect(core, contains('contact.status != ContactStatus.accepted'));
  });
}
