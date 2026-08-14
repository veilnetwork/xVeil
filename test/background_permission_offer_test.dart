// When the app asks to be exempted from battery optimisation, and when it
// must not.
//
// The exemption is not a nicety. The background node runs inside a foreground
// service, and from Android 12 the platform refuses `startForeground()` for an
// app it does not consider eligible — which an app without the exemption stops
// being the moment it is backgrounded. Measured on a phone doing nothing
// unusual: let the screen switch off and the node is gone, no sessions with any
// seed, nothing delivered, while the app still reports itself ready. So the
// question is worth asking once at start-up.
//
// Which is exactly why the answers have to be separated. "Later" and "don't ask
// again" are different answers from different people, and an offer that cannot
// be silenced becomes a nag while one that silences itself too easily removes
// the feature by accident.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/network/background_permission_offer.dart';

void main() {
  group('shouldOfferBackgroundPermission', () {
    test('asks when the exemption is missing and nobody has silenced it', () {
      expect(
        shouldOfferBackgroundPermission(
          onAndroid: true,
          exempt: false,
          suppressed: false,
        ),
        isTrue,
      );
    });

    test('says nothing once the exemption is granted', () {
      expect(
        shouldOfferBackgroundPermission(
          onAndroid: true,
          exempt: true,
          suppressed: false,
        ),
        isFalse,
      );
    });

    test('says nothing after "don\'t ask again"', () {
      expect(
        shouldOfferBackgroundPermission(
          onAndroid: true,
          exempt: false,
          suppressed: true,
        ),
        isFalse,
      );
    });

    // Every other platform either has no such setting or expresses it
    // differently; asking there would be a dialog about a switch that does not
    // exist.
    test('never asks off Android, whatever the other answers are', () {
      for (final exempt in [true, false]) {
        for (final suppressed in [true, false]) {
          expect(
            shouldOfferBackgroundPermission(
              onAndroid: false,
              exempt: exempt,
              suppressed: suppressed,
            ),
            isFalse,
            reason: 'exempt=$exempt suppressed=$suppressed',
          );
        }
      }
    });

    // Suppression must not be mistaken for consent. Someone who dismissed the
    // start-up offer has said nothing about whether they want the exemption —
    // they may grant it from the Network screen the next day — so the two must
    // stay separate keys and separate questions.
    test('a granted exemption and a silenced offer are independent', () {
      expect(
        shouldOfferBackgroundPermission(
          onAndroid: true,
          exempt: true,
          suppressed: true,
        ),
        isFalse,
      );
      // The pair that matters: silenced, and still not exempt. The app stays
      // quiet — and that is precisely why the dialog body has to name where the
      // switch lives, because nothing will bring it up again.
      expect(
        shouldOfferBackgroundPermission(
          onAndroid: true,
          exempt: false,
          suppressed: true,
        ),
        isFalse,
      );
    });
  });

  // The key is app-wide on purpose: one installed app, one OS setting. An
  // identity-scoped key would ask the same question about the same switch again
  // under a second identity.
  test('the suppression key is not identity-scoped', () {
    expect(kBackgroundOfferSuppressedPrefKey, isNot(contains('identity')));
    expect(kBackgroundOfferSuppressedPrefKey, endsWith('.v1'));
  });
}
