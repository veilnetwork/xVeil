import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/messaging_core.dart';

/// The beacon that keeps two conversations reconciled had exactly one reason to
/// slow down — "nobody answered" — and none for "nothing happened". A peer that
/// answers an empty beacon with an equally empty one resets the first, so two
/// idle conversations sat at one beacon every 20 s each way for as long as both
/// stayed online. From the constants that is 0.1 frames/s per idle contact
/// against a whole-node floor of ~2.4 frames/s: six of them, a quarter of
/// everything the node sends, to say nothing had changed.
void main() {
  group('beaconInterval', () {
    test('base cadence when there is both an answer and something to say', () {
      expect(
        beaconInterval(unanswered: 0, quiet: 0),
        const Duration(seconds: 20),
      );
    });

    test('a quiet conversation backs off on its own, with nobody silent', () {
      // unanswered stays 0 throughout — the peer IS answering. This is the arm
      // that did not exist.
      expect(
        beaconInterval(unanswered: 0, quiet: 1),
        const Duration(seconds: 40),
      );
      expect(
        beaconInterval(unanswered: 0, quiet: 3),
        const Duration(seconds: 160),
      );
      expect(
        beaconInterval(unanswered: 0, quiet: 4),
        const Duration(seconds: 320),
      );
      // 20 s * 2^5 = 640 s, which the ten-minute cap trims to 600.
      expect(
        beaconInterval(unanswered: 0, quiet: 5),
        const Duration(minutes: 10),
      );
    });

    test('the longer streak wins — neither reason cancels the other', () {
      expect(
        beaconInterval(unanswered: 4, quiet: 1),
        beaconInterval(unanswered: 4, quiet: 0),
      );
      expect(
        beaconInterval(unanswered: 1, quiet: 4),
        beaconInterval(unanswered: 4, quiet: 0),
      );
    });

    test('capped at ten minutes however long either streak runs', () {
      for (final n in [6, 10, 100, 1000]) {
        expect(
          beaconInterval(unanswered: n, quiet: 0),
          const Duration(minutes: 10),
          reason: 'unanswered=$n',
        );
        expect(
          beaconInterval(unanswered: 0, quiet: n),
          const Duration(minutes: 10),
          reason: 'quiet=$n',
        );
      }
    });

    test('never shorter than the base — a streak may only slow it down', () {
      for (var u = 0; u < 12; u++) {
        for (var q = 0; q < 12; q++) {
          expect(
            beaconInterval(unanswered: u, quiet: q),
            greaterThanOrEqualTo(const Duration(seconds: 20)),
            reason: 'unanswered=$u quiet=$q',
          );
        }
      }
    });
  });

  group('beaconStatement', () {
    String st({
      Map<String, int> hw = const {'a': 1},
      Map<String, List<List<int>>> holes = const {},
      int floor = 0,
    }) => beaconStatement(
      highWater: hw,
      holes: holes,
      selfHex: 'me',
      ownFloor: floor,
    );

    test(
      'the same state states the same thing — the quiet streak can start',
      () {
        expect(st(), st());
      },
    );

    test('a moved high-water is news', () {
      expect(st(hw: {'a': 2}), isNot(st(hw: {'a': 1})));
    });

    test('a new hole is news', () {
      expect(
        st(
          holes: {
            'a': [
              [2, 3],
            ],
          },
        ),
        isNot(st()),
      );
    });

    test('a floor is news', () {
      expect(st(floor: 5), isNot(st()));
    });

    test('the timestamp is NOT part of it', () {
      // The wire body carries `ep`, which moves every tick. If the comparison
      // used the whole body, every beacon would look new and the quiet streak
      // could never begin — the bug this guards is silent, not loud.
      expect(st().contains('ep'), isFalse);
    });
  });
}
