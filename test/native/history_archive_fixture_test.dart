import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart';
import '../support/history_archive_fixture.dart';

void main() {
  test('crash row is optional and strictly inside the archive', () {
    expect(historyCrashRow(null, 100000), isNull);
    for (final index in [1, 350, 50000, 99999]) {
      expect(historyCrashRow('$index', 100000), index);
    }
    for (final raw in ['', 'invalid', '-1', '0', '100000', '100001', '3.5']) {
      expect(() => historyCrashRow(raw, 100000), throwsArgumentError);
    }
  });
  test('archive append-order census exposes only shape counts', () {
    List<Message> rows(List<int> times, {List<String>? ids}) => [
      for (var i = 0; i < times.length; i++)
        Message(
          id: ids?[i] ?? 'PRIVATE_$i',
          conversationId: 'PRIVATE_PEER',
          direction: MessageDirection.outgoing,
          body: 'PRIVATE_BODY',
          timestamp: DateTime.fromMillisecondsSinceEpoch(times[i]),
        ),
    ];
    expect(historyArchiveOrderShape(rows([0, 1, 2])), {
      'rows': 3,
      'descendingPairs': 0,
      'firstRunRows': 3,
      'secondRunRows': 0,
      'fullyOrdered': true,
      'twoRunsWithBoundedSide': false,
    });
    expect(historyArchiveOrderShape(rows([3, 0, 1, 2])), {
      'rows': 4,
      'descendingPairs': 1,
      'firstRunRows': 1,
      'secondRunRows': 3,
      'fullyOrdered': false,
      'twoRunsWithBoundedSide': true,
    });
    expect(historyArchiveOrderShape(rows([2, 1, 0]))['descendingPairs'], 2);
    expect(
      historyArchiveOrderShape(
        rows([0, 0], ids: ['z', 'a']),
      )['descendingPairs'],
      1,
    );
    expect(historyArchiveOrderShape(rows([]))['rows'], 0);
    expect(
      historyArchiveOrderShape(
        rows([
          for (var i = 129; i < 258; i++) i,
          for (var i = 0; i < 129; i++) i,
        ]),
      )['twoRunsWithBoundedSide'],
      false,
    );
    expect(
      historyArchiveOrderShape(rows([0])).toString(),
      isNot(contains('PRIVATE_')),
    );
  });
  test('default archive remains 512 rows', () {
    expect(historyArchiveRows(null), 512);
  });
  for (final count in [32, 512, 2000, 3000, 10000, 100000]) {
    test('bounded archive of $count rows is supported', () {
      expect(historyArchiveRows('$count'), count);
    });
  }
  for (final raw in ['', 'not-a-number', '-1', '0', '31', '100001', '1e9']) {
    test('invalid archive count is refused: $raw', () {
      expect(() => historyArchiveRows(raw), throwsArgumentError);
    });
  }
}
