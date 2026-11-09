import 'dart:collection';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/message_history_order.dart';

class _CountedRows extends ListBase<Message> {
  _CountedRows(this.rows);
  final List<Message> rows;
  int reads = 0;
  @override
  int get length => rows.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  Message operator [](int index) {
    reads++;
    return rows[index];
  }

  @override
  void operator []=(int index, Message value) =>
      throw UnsupportedError('read only');
}

Message row(String id, int micros, {bool utc = true}) => Message(
  id: id,
  conversationId: 'fixture',
  direction: MessageDirection.outgoing,
  body: id,
  timestamp: DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: utc),
  status: MessageStatus.delivered,
);

void main() {
  test('wire milliseconds and IDs define the same order as every cursor', () {
    final rows = [row('z', 100100), row('a', 100900), row('m', 100500)];
    rows.sort(compareMessageHistoryOrder);
    expect(rows.map((m) => m.id), ['a', 'm', 'z']);
    expect(rows.map((m) => m.timestamp.microsecondsSinceEpoch), [
      100900,
      100500,
      100100,
    ]);
    for (var i = 0; i < rows.length; i++) {
      final cursor = rows[i];
      expect(
        messageHistoryStartAfter(
          rows,
          cursor.timestamp.millisecondsSinceEpoch,
          cursor.id,
        ),
        i + 1,
      );
    }
  });

  test('equal instants in different zones use the same ID tie break', () {
    final utc = row('z', 0);
    final local = row('a', 0, utc: false);
    expect(compareMessageHistoryOrder(local, utc), lessThan(0));
    expect(compareMessageHistoryCursor(local, 0, 'a'), 0);
  });

  test(
    'empty, boundary, deleted and duplicate positions match a linear oracle',
    () {
      final rows = [
        row('a', -1000),
        row('b', 0),
        row('b', 0),
        row('d', 0),
        row('z', 1000),
      ];
      final cursors = [
        (-2, ''),
        (-1, 'a'),
        (0, ''),
        (0, 'a'),
        (0, 'b'),
        (0, 'c'),
        (0, 'd'),
        (0, 'zz'),
        (1, 'z'),
        (2, ''),
      ];
      for (final (ts, id) in cursors) {
        final expected = rows.indexWhere(
          (m) => compareMessageHistoryCursor(m, ts, id) > 0,
        );
        expect(
          messageHistoryStartAfter(List.unmodifiable(rows), ts, id),
          expected == -1 ? rows.length : expected,
        );
      }
      expect(messageHistoryStartAfter(const [], 0, ''), 0);
    },
  );

  test('all windows preserve an independent millisecond and ID oracle', () {
    final random = Random(7319);
    for (final count in [1, 2, 63, 64, 127, 128, 129, 1000]) {
      final rows = [
        for (var i = 0; i < count; i++)
          row(
            'id-${i.toString().padLeft(4, '0')}',
            random.nextInt(5000) - 2500,
          ),
      ];
      // Deliberately keep the oracle independent of the production comparator.
      final expected = List<Message>.of(rows)
        ..sort((a, b) {
          final left = a.timestamp.millisecondsSinceEpoch;
          final right = b.timestamp.millisecondsSinceEpoch;
          return left == right ? a.id.compareTo(b.id) : left.compareTo(right);
        });
      rows.shuffle(random);
      rows.sort(compareMessageHistoryOrder);
      expect(rows, expected);
      for (final limit in [1, 64, 128]) {
        final held = <Message>[];
        int? ts;
        var id = '';
        while (held.length < count) {
          final start = ts == null ? 0 : messageHistoryStartAfter(rows, ts, id);
          final page = rows.getRange(start, min(start + limit, rows.length));
          held.addAll(page);
          final last = held.last;
          ts = last.timestamp.millisecondsSinceEpoch;
          id = last.id;
        }
        expect(held, expected);
      }
    }
  });

  test('100000-row tail lookup reads at most 17 rows and keeps lookahead', () {
    final rows = _CountedRows([
      for (var i = 0; i < 100000; i++) row('m$i', i * 1000),
    ]);
    final start = messageHistoryStartAfter(rows, 99871, 'm99871');
    expect(start, 99872);
    expect(rows.reads, lessThanOrEqualTo(17));
    final page = rows.getRange(start, min(start + 129, rows.length)).toList();
    expect(page, hasLength(128));
    expect(page.first.id, 'm99872');
    expect(page.last.id, 'm99999');
    rows.reads = 0;
    expect(messageHistoryStartAfter(rows, 100000, ''), 100000);
    expect(rows.reads, lessThanOrEqualTo(17));
  });

  test(
    '100000-row pagination copies exactly the same rows with bounded lookups',
    () {
      final rows = _CountedRows([
        for (var i = 0; i < 100000; i++) row('m$i', i * 1000),
      ]);
      var cursor = -1;
      var count = 0, pages = 0, lookupReads = 0;
      while (count < rows.length) {
        final before = rows.reads;
        final start = messageHistoryStartAfter(rows, cursor, 'm$cursor');
        lookupReads += rows.reads - before;
        final end = min(start + 128, rows.length);
        for (var i = start; i < end; i++) {
          final message = rows[i];
          expect(message.id, 'm$count');
          cursor = message.timestamp.millisecondsSinceEpoch;
          count++;
        }
        pages++;
      }
      expect(count, 100000);
      expect(pages, 782);
      expect(lookupReads, lessThanOrEqualTo(782 * 17));
      // A from-zero filter has to visit this prefix even before copying pages.
      expect(128 * 781 * 782 ~/ 2, 39087488);
    },
  );
}
