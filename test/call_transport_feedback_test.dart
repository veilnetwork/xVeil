import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';

void main() {
  test('split transport feedback requires peer and native support', () {
    for (final version in [null, 1, 2, 3]) {
      expect(
        useIndependentCallTransportFeedback(
          version,
          nativeSupportsFeedback: true,
        ),
        isFalse,
      );
    }
    for (final version in [4, 5]) {
      expect(
        useIndependentCallTransportFeedback(
          version,
          nativeSupportsFeedback: true,
        ),
        isTrue,
      );
      expect(
        useIndependentCallTransportFeedback(
          version,
          nativeSupportsFeedback: false,
        ),
        isFalse,
      );
    }
  });
}
