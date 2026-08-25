import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/disappearing_messages.dart';
import 'package:xveil/state/device_sync_bridge.dart';

/// A linked device of this identity is authenticated, and that is not the same
/// as believed.
///
/// The direct wire refuses a retention policy stamped ahead of this device's
/// clock, or carrying a window outside the range the expiry arithmetic can
/// hold. The device-sync mirror of the SAME policy checked only that the stamp
/// was an integer and took the rest verbatim — so a sibling running an old
/// build, a corrupted store, or a device somebody else now holds could mirror
/// exactly what the wire refuses (report14 X14-M5).
///
/// Last-writer-wins is what makes a future stamp expensive: it is not an odd
/// value in a record, it is a permanent victory over every honest update after
/// it. With a one-second window under it, the conversation is deleted.
Map<String, Object?> _payload({
  Object? dsa,
  Object? dtl,
  Object? har,
  Object? dsb,
}) => {'dsa': dsa, 'dtl': dtl, 'har': har, 'dsb': dsb};

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  group('the mirror believes what the wire believes', () {
    test('an ordinary mirrored policy is taken', () {
      final got = DisappearingSetting.fromMirrorJson(
        _payload(
          dsa: now.millisecondsSinceEpoch - 60000,
          dtl: 3600,
          har: 30,
          dsb: 'ab' * 32,
        ),
        now: now,
      );
      expect(
        got,
        isNotNull,
        reason:
            'the refusals below prove nothing if '
            'nothing is ever accepted',
      );
      expect(got!.ttlSeconds, 3600);
      expect(got.hideAfterReadSeconds, 30);
      expect(got.setBy, 'ab' * 32);
    });

    test('a window turned OFF is an answer, not a malformation', () {
      final got = DisappearingSetting.fromMirrorJson(
        _payload(dsa: now.millisecondsSinceEpoch - 1, dtl: null, har: null),
        now: now,
      );
      expect(got, isNotNull);
      expect(got!.ttlSeconds, isNull);
    });

    test('a stamp from the future is refused', () {
      expect(
        DisappearingSetting.fromMirrorJson(
          _payload(
            dsa:
                now.millisecondsSinceEpoch +
                kDisappearingClockSkew.inMilliseconds +
                1,
            dtl: 1,
          ),
          now: now,
        ),
        isNull,
        reason:
            'last-writer-wins turns a future stamp into a permanent '
            'victory, and the window under it deletes the conversation',
      );
    });

    test('a stamp inside the allowed skew is still taken', () {
      expect(
        DisappearingSetting.fromMirrorJson(
          _payload(
            dsa:
                now.millisecondsSinceEpoch +
                kDisappearingClockSkew.inMilliseconds -
                1,
            dtl: 60,
          ),
          now: now,
        ),
        isNotNull,
        reason:
            'two devices of one person do not share a clock to the '
            'millisecond',
      );
    });

    test('a window past what the expiry arithmetic can hold is refused', () {
      for (final ttl in <Object>[
        kDisappearingMaxSeconds + 1,
        -1,
        9223372036854775807,
        'an hour',
      ]) {
        expect(
          DisappearingSetting.fromMirrorJson(
            _payload(dsa: now.millisecondsSinceEpoch, dtl: ttl),
            now: now,
          ),
          isNull,
          reason: 'dtl=$ttl',
        );
      }
    });

    test('a hide-after-read window out of range is refused', () {
      for (final hide in <Object>[0, -5, kDisappearingMaxSeconds + 1, 'soon']) {
        expect(
          DisappearingSetting.fromMirrorJson(
            _payload(dsa: now.millisecondsSinceEpoch, dtl: 60, har: hide),
            now: now,
          ),
          isNull,
          reason: 'har=$hide',
        );
      }
    });

    test('a setter that is not a name is refused', () {
      expect(
        DisappearingSetting.fromMirrorJson(
          _payload(dsa: now.millisecondsSinceEpoch, dtl: 60, dsb: 42),
          now: now,
        ),
        isNull,
      );
    });

    test('no stamp is silence, and silence changes nothing', () {
      expect(DisappearingSetting.fromMirrorJson(const {}), isNull);
      expect(
        DisappearingSetting.fromMirrorJson(_payload(dsa: 'yesterday')),
        isNull,
      );
    });
  });

  test('the bridge reads policies through that validator', () {
    // The bridge is where a mirrored event becomes a stored policy, and it is
    // the seam a refusal has to reach to matter.
    expect(
      disappearingFromPayload(
        _payload(dsa: DateTime.now().millisecondsSinceEpoch + 86400000, dtl: 1),
      ),
      isNull,
      reason: 'a policy the wire would refuse must not arrive by the side door',
    );
    expect(
      disappearingFromPayload(
        _payload(dsa: DateTime.now().millisecondsSinceEpoch - 1000, dtl: 600),
      ),
      isNotNull,
    );
  });
}
