// The certificate an identity cannot be restored without, and the reminder
// that it has not been saved.
//
// The identity is named by a master whose Falcon half exists only inside its
// credential. The 24 words restore a DIFFERENT identity, so until a copy of
// the certificate exists somewhere, this identity is one device failure away
// from being gone. The reminder is the only thing that says so, which is why
// the flag behind it must mean "a copy exists" and not "a write returned".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/devices_screen.dart';

void main() {
  final screen = File('lib/features/settings/devices_screen.dart')
      .readAsStringSync();

  group('the sheet opens once, after an identity is created', () {
    test('it needs the flag, a ready node, and not having fired', () {
      expect(
        shouldOpenRecoverySheet(
          autoRecovery: true,
          ready: true,
          alreadyOpened: false,
        ),
        isTrue,
      );
      // Right after onboarding the node is still coming up: firing then burns
      // the one shot on a call that returns at its own null guard, and the
      // person is left on a list that never opens anything.
      expect(
        shouldOpenRecoverySheet(
          autoRecovery: true,
          ready: false,
          alreadyOpened: false,
        ),
        isFalse,
        reason: 'must wait for the node, not spend the shot on nothing',
      );
      expect(
        shouldOpenRecoverySheet(
          autoRecovery: true,
          ready: true,
          alreadyOpened: true,
        ),
        isFalse,
        reason: 'one shot, or the sheet reopens on every rebuild',
      );
      expect(
        shouldOpenRecoverySheet(
          autoRecovery: false,
          ready: true,
          alreadyOpened: false,
        ),
        isFalse,
      );
    });

    test('it has its own one-shot, separate from the device-link sheet', () {
      // A single shared flag would let whichever route fired first swallow the
      // other, and the two arrive by different routes.
      expect(screen.contains('_autoRecoveryFired'), isTrue);
      expect(screen.contains('_autoJoinFired'), isTrue);
      expect(
        screen.contains('_autoRecoveryFired = true'),
        isTrue,
        reason: 'the shot must actually be spent',
      );
    });
  });

  test('saved means the file read back, not that the write returned', () {
    final start = screen.indexOf('Future<void> _saveCertificateToFile() async {');
    expect(start, isNot(-1), reason: 'the writer was renamed');
    final open = screen.indexOf('{', start);
    var depth = 0;
    var end = screen.length;
    for (var i = open; i < screen.length; i++) {
      if (screen[i] == '{') depth++;
      if (screen[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    final body = screen.substring(start, end);
    final readBack = body.indexOf('readAsString');
    final marked = body.indexOf('markRecoveryCertificateSaved');
    expect(readBack, isNot(-1), reason: 'the file must be read back');
    expect(
      marked,
      greaterThan(readBack),
      reason:
          'a write that reported success and left nothing behind would clear '
          'the only warning this person has',
    );
  });

  test('the reminder stands until a copy exists, and is the action itself', () {
    expect(
      screen.contains('!_certificateSaved'),
      isTrue,
      reason: 'the reminder must be conditioned on not having saved',
    );
    // Tapping it must DO the thing. A notice that only says "you should"
    // leaves the person hunting for where.
    final card = screen.substring(screen.indexOf('!_certificateSaved'));
    expect(
      card.substring(0, card.indexOf('if (_loading)')).contains(
        'onTap: _showRecoveryExport',
      ),
      isTrue,
      reason: 'the reminder must open the export, not merely mention it',
    );
  });

  test('unknown is treated as saved, so the warning stays believable', () {
    expect(
      screen.contains('hasSavedRecoveryCertificate() ?? true'),
      isTrue,
      reason:
          'a reminder that appears because a read failed is crying wolf, and '
          'this one has to be believed the one time it matters',
    );
  });
}
