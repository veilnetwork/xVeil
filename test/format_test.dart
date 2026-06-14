import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/format.dart';

void main() {
  test('formatHhmm zero-pads hours and minutes', () {
    expect(formatHhmm(DateTime(2026, 6, 14, 9, 5)), '09:05');
    expect(formatHhmm(DateTime(2026, 6, 14, 23, 59)), '23:59');
    expect(formatHhmm(DateTime(2026, 6, 14, 0, 0)), '00:00');
  });
}
