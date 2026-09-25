import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/device_silence.dart';

void main() {
  final now = DateTime(2026, 9, 25, 12);

  test('a device silent for a month is offered for unlinking, not before', () {
    expect(
      suggestUnlinking(silentSince: now.subtract(kDeviceAwayLong), now: now),
      isTrue,
    );
    expect(
      suggestUnlinking(
        silentSince: now.subtract(const Duration(days: 29, hours: 23)),
        now: now,
      ),
      isFalse,
      reason: 'a phone in a drawer over a holiday is not gone',
    );
  });

  test('unknown silence is never a reason to unlink', () {
    // Neither heard nor ever queued for: nothing says it is gone.
    expect(suggestUnlinking(silentSince: null, now: now), isFalse);
  });
}
