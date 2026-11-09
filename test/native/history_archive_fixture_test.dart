import 'package:flutter_test/flutter_test.dart';
import '../support/history_archive_fixture.dart';

void main() {
  test('default archive remains 512 rows', () {
    expect(historyArchiveRows(null), 512);
  });
  for (final count in [32, 512, 2000, 3000, 10000]) {
    test('bounded archive of $count rows is supported', () {
      expect(historyArchiveRows('$count'), count);
    });
  }
  for (final raw in ['', 'not-a-number', '-1', '0', '31', '10001', '1e9']) {
    test('invalid archive count is refused: $raw', () {
      expect(() => historyArchiveRows(raw), throwsArgumentError);
    });
  }
}
