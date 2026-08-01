import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/roster.dart';

Uint8List keys(int fill) => Uint8List.fromList(List.filled(64, fill));

void main() {
  group('identitySpaceCollides', () {
    test('a password already used by a child is a collision', () {
      // The case that overwrote an existing identity and left two roster rows
      // pointing at one space.
      expect(
        identitySpaceCollides(
          masterKeys: keys(0),
          roster: [
            RosterEntry(label: 'Personal', spaceKeys: keys(1)),
            RosterEntry(label: 'Work', spaceKeys: keys(2)),
          ],
          candidateKeys: keys(2),
        ),
        isTrue,
      );
    });

    test('the master password is a collision', () {
      // The worse case: the master's roster is replaced by child data, and
      // deleting that "child" then deletes the master's storage.
      expect(
        identitySpaceCollides(
          masterKeys: keys(9),
          roster: [RosterEntry(label: 'Personal', spaceKeys: keys(1))],
          candidateKeys: keys(9),
        ),
        isTrue,
      );
    });

    test('a fresh password is not a collision', () {
      expect(
        identitySpaceCollides(
          masterKeys: keys(0),
          roster: [RosterEntry(label: 'Personal', spaceKeys: keys(1))],
          candidateKeys: keys(7),
        ),
        isFalse,
      );
    });

    test('an absent master is tolerated, not treated as a match', () {
      // First conversion: there is no master yet. A null must not compare equal
      // to a candidate, or the very first identity could never be added.
      expect(
        identitySpaceCollides(
          masterKeys: null,
          roster: const [],
          candidateKeys: keys(3),
        ),
        isFalse,
      );
    });

    test('comparison is over the whole key, not a prefix', () {
      // A prefix comparison would both miss real collisions and invent fake
      // ones. Two keys differing only in the last byte are different spaces.
      final a = keys(5);
      final b = keys(5)..[63] = 6;
      expect(
        identitySpaceCollides(
          masterKeys: null,
          roster: [RosterEntry(label: 'x', spaceKeys: a)],
          candidateKeys: b,
        ),
        isFalse,
      );
      expect(
        identitySpaceCollides(
          masterKeys: null,
          roster: [RosterEntry(label: 'x', spaceKeys: a)],
          candidateKeys: keys(5),
        ),
        isTrue,
      );
    });

    test('a differently-sized key is not a match', () {
      expect(
        identitySpaceCollides(
          masterKeys: Uint8List.fromList(List.filled(32, 5)),
          roster: const [],
          candidateKeys: keys(5),
        ),
        isFalse,
      );
    });
  });
}
