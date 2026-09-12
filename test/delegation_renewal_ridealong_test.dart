// The delegation is carried forward wherever the secret is already typed.
//
// The window is seven days and only the master can extend it, so a device
// nobody unlocks for a week goes quiet — and the fix for that must not be
// "ask them again in a week". Every place that already asks for the secret
// renews too, which is what makes the prompt rare rather than weekly.
//
// A source guard because the alternative is a widget test per sheet over a
// real group service; what has to hold is that no prompt is left out, and
// that is a property of the file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final screen = File('lib/features/settings/devices_screen.dart')
      .readAsStringSync();
  final service = File('lib/state/group_service.dart').readAsStringSync();

  test('every place that opens the credential renews along with it', () {
    // Counting was the first version of this guard and it proved nothing:
    // "renewals >= opens" passes while one site has two and another has none.
    // What has to hold is the PAIRING — each open followed by a renewal.
    final opens = 'openLocalSovereign('.allMatches(screen).toList();
    expect(
      opens,
      isNotEmpty,
      reason: 'the screen must still be the place a secret is typed',
    );
    final unpaired = <String>[];
    for (final m in opens) {
      // The renewal rides immediately along; a few lines is generous.
      final after = screen.substring(
        m.end,
        (m.end + 400).clamp(0, screen.length),
      );
      if (!after.contains('renewOwnDelegationQuietly(')) {
        final line = '\n'.allMatches(screen.substring(0, m.start)).length + 1;
        unpaired.add('line $line');
      }
    }
    expect(
      unpaired,
      isEmpty,
      reason:
          'a prompt that opens the credential and does not carry the '
          'delegation forward is a week closer to a device going quiet: '
          '${unpaired.join(', ')}',
    );
  });

  test('the ride-along never fails the operation it rides on', () {
    // Anchored on the NAME, not the signature: the return type changed once
    // already (void -> bool, so a deliberate caller can report the outcome)
    // and took this guard's anchor with it.
    final start = service.indexOf('renewOwnDelegationQuietly(String secret)');
    expect(start, isNot(-1), reason: 'the ride-along was renamed or removed');
    final open = service.indexOf('async {', start) + 'async '.length;
    var depth = 0;
    var end = service.length;
    for (var i = open; i < service.length; i++) {
      if (service[i] == '{') depth++;
      if (service[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    final body = service.substring(start, end);
    expect(
      body.contains('catch'),
      isTrue,
      reason:
          'this rides along with somebody else\'s operation and must never be '
          'the reason it reports a failure',
    );
    // And it must not throw its own way out either.
    expect(
      body.contains('rethrow'),
      isFalse,
      reason: 'rethrowing would fail the operation the person actually asked '
          'for, over a renewal they did not',
    );
  });

  test('a still-fresh window is not reported as a failure', () {
    final stack = File('lib/data/veil_stack.dart').readAsStringSync();
    expect(
      stack.contains('must move the window forward'),
      isTrue,
      reason:
          'the native refusal for "already fresh" must be told apart from a '
          'real failure, or every opportunistic renewal logs an error',
    );
  });

  test('the renewal stages the device key in a directory only it can read', () {
    final stack = File('lib/data/veil_stack.dart').readAsStringSync();
    final start = stack.indexOf('static Future<bool> renewOwnDelegation(');
    expect(start, isNot(-1));
    final body = stack.substring(start, start + 3000);
    expect(
      body.contains('createTemp('),
      isTrue,
      reason:
          'what is written there is device_identity_sk.bin — this device\'s '
          'signing key — and a path built by hand gets whatever the umask says',
    );
  });
}
