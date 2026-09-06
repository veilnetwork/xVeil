// A successful re-send must not answer with a snackbar.
//
// It used to: `chatRequestSent` — the SAME sentence already standing one line
// above, in the pending-request footer — raised over the two buttons it was
// describing. Pressing "Send again" hid "Send again" and "Cancel" to announce
// that "Send again" had worked. Reported from a phone.
//
// Read out of the source because reaching that branch needs a live messaging
// service and a peer whose request was accepted for deposit, which no widget
// test here has. The shape is narrow: it reads the SUCCESS branch of _resend,
// not the file, so the failure snackbar beside it — which carries its own
// action and is the exceptional case — is untouched.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The body of `_resend` after the "not deposited" early return.
String resendSuccessBranch(String source) {
  final at = source.indexOf('Future<void> _resend() async {');
  expect(at, isNot(-1), reason: '_resend was renamed');
  final end = source.indexOf('\n  }', at);
  expect(end, isNot(-1));
  final body = source.substring(at, end);
  final guard = body.indexOf('_reportRequestUndelivered();');
  expect(guard, isNot(-1), reason: 'the failure path is gone');
  return body.substring(guard);
}

void main() {
  final source = File(
    'lib/features/chat/chat_screen.dart',
  ).readAsStringSync();

  test('a re-send that worked says so without covering the actions', () {
    expect(
      resendSuccessBranch(source),
      isNot(contains('showSnackBar')),
      reason:
          'the confirmation is raised over the footer it is confirming, so it '
          'hides "Send again" and "Cancel" the moment either is useful',
    );
  });

  test('and it does say so', () {
    // Removing the snackbar without putting the confirmation anywhere would
    // leave the screen unchanged by a press, which reads as "nothing
    // happened" — the complaint this came from, in the other direction.
    expect(
      resendSuccessBranch(source),
      contains('_justResent'),
      reason: 'a re-send now leaves no trace at all',
    );
    expect(
      source,
      contains('_justResent ? l.chatRequestResent'),
      reason: 'the footer no longer shows that it went out again',
    );
  });
}
