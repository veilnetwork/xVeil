import 'dart:collection';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/message_history_order.dart';

class _CountedRows extends ListBase<Message> {
  _CountedRows(this.rows, {this.readOnly = true});
  final List<Message> rows;
  final bool readOnly;
  int reads = 0, writes = 0, sortCalls = 0;
  final buffers = <int>[];
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
  void operator []=(int index, Message value) {
    if (readOnly) throw UnsupportedError('read only');
    writes++;
    rows[index] = value;
  }

  @override
  List<Message> sublist(int start, [int? end]) {
    buffers.add((end ?? length) - start);
    return super.sublist(start, end);
  }

  @override
  void sort([int Function(Message, Message)? compare]) {
    sortCalls++;
    super.sort(compare);
  }
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
  test('history windows match full fresh sort across layouts and cursors', () {
    final random = Random(739);
    for (final count in [0, 1, 2, 3, 16, 129, 256, 1000]) {
      final ordered = [
        for (var i = 0; i < count; i++)
          row('m${i.toString().padLeft(4, '0')}', (i ~/ 3) * 1000 + i % 3),
      ];
      final shuffled = List<Message>.of(ordered)..shuffle(random);
      for (final input in [
        ordered,
        ordered.reversed.toList(),
        shuffled,
        [...ordered.skip(count ~/ 2), ...ordered.take(count ~/ 2)],
        [
          for (var i = 0; i < count; i += 2) ordered[i],
          for (var i = 1; i < count; i += 2) ordered[i],
        ],
      ]) {
        final expected = List<Message>.of(input)
          ..sort(compareMessageHistoryOrder);
        for (final cursor in <(int, String)?>[
          null,
          (-1, ''),
          (0, ''),
          (0, 'm0001'),
          (0, 'm0001x'),
          if (count > 0)
            (
              expected[count ~/ 2].timestamp.millisecondsSinceEpoch,
              expected[count ~/ 2].id,
            ),
          (1 << 60, 'after-tail'),
        ]) {
          final suffix = expected
              .where(
                (m) =>
                    cursor == null ||
                    compareMessageHistoryCursor(m, cursor.$1, cursor.$2) > 0,
              )
              .toList();
          for (final limit in [0, 1, 2, 8, 64, 128, 257, 1 << 62]) {
            final source = List<Message>.unmodifiable(input);
            final actual = messageHistoryWindow(
              source,
              limit: limit,
              afterTimestampMs: cursor?.$1,
              afterId: cursor?.$2,
            );
            expect(actual, suffix.take(limit));
            actual.clear();
            expect(source, input);
          }
        }
      }
    }
  });

  test('100000-row windows do not materialize a whole two-run merge', () {
    final ordered = [for (var i = 0; i < 100000; i++) row('m$i', i * 1000)];
    for (final input in [
      ordered,
      [ordered.last, ...ordered.take(ordered.length - 1)],
      [...ordered.skip(50000), ...ordered.take(50000)],
      [
        for (var i = 0; i < 100000; i += 2) ordered[i],
        for (var i = 1; i < 100000; i += 2) ordered[i],
      ],
    ]) {
      final rows = _CountedRows(input);
      final selected = messageHistoryWindow(
        rows,
        limit: 257,
        afterTimestampMs: 99,
        afterId: 'm99',
      );
      expect(selected, ordered.skip(100).take(257));
      expect(rows.reads, lessThanOrEqualTo(101024));
      expect(rows.writes, 0);
      expect(rows.buffers, isEmpty);
    }
  });

  test('window rejects partial cursors and observes a later changed view', () {
    final rows = [row('late', 3000), row('first', 1000), row('next', 2000)];
    expect(messageHistoryWindow(rows, limit: 2).map((m) => m.id), [
      'first',
      'next',
    ]);
    rows[1] = row('replacement', 4000);
    expect(messageHistoryWindow(rows, limit: 2).map((m) => m.id), [
      'next',
      'late',
    ]);
    expect(() => messageHistoryWindow(rows, limit: -1), throwsArgumentError);
    expect(
      () => messageHistoryWindow(rows, limit: 1, afterTimestampMs: 0),
      throwsArgumentError,
    );
    expect(
      () => messageHistoryWindow(rows, limit: 0, afterId: ''),
      throwsArgumentError,
    );
  });

  test('100000 already ordered rows are read once without sort writes', () {
    final source = [for (var i = 0; i < 100000; i++) row('m$i', i * 1000)];
    final rows = _CountedRows(List.of(source), readOnly: false);
    sortMessageHistory(rows);
    expect(rows.reads, 100000);
    expect(rows.writes, 0);
    expect(rows.rows, source);
  });

  test(
    'two sorted runs use only a bounded smaller buffer or the ordinary sort',
    () {
      for (final count in [2, 129, 200, 256, 100000]) {
        final expected = [for (var i = 0; i < count; i++) row('m$i', i * 1000)];
        for (final split in {
          1,
          2,
          64,
          128,
          129,
          count ~/ 2,
          count - 128,
          count - 1,
        }.where((i) => i > 0 && i < count)) {
          final rows = _CountedRows([
            ...expected.skip(count - split),
            ...expected.take(count - split),
          ], readOnly: false);
          sortMessageHistory(rows);
          expect(rows.rows, expected);
          final small = min(split, count - split);
          if (small <= 128) {
            expect(rows.sortCalls, 0);
            expect(rows.buffers, [small]);
            expect(rows.reads, lessThanOrEqualTo(count * 3 + 128));
          } else {
            expect(rows.sortCalls, 1);
            expect(rows.buffers, isEmpty);
          }
        }
      }
      final equalMs = [
        row('c', 100100),
        row('d', 100200),
        row('a', 100300),
        row('b', 100400),
      ];
      sortMessageHistory(equalMs);
      expect(equalMs.map((m) => m.id), ['a', 'b', 'c', 'd']);
      for (final times in [
        [1, 3, 5, 2, 4, 6],
        [1, 3, 5, 7, 2, 4],
        [2, 4, 1, 3, 5, 7],
      ]) {
        final interleaved = [for (final t in times) row('m$t', t * 1000)];
        sortMessageHistory(interleaved);
        expect(
          interleaved.map((m) => m.timestamp.millisecondsSinceEpoch),
          times.toList()..sort(),
        );
      }
    },
  );

  test('fresh late inversions and millisecond ID inversions are sorted', () {
    final random = Random(419);
    for (final count in [0, 1, 2, 63, 64, 129, 1000]) {
      final source = [
        for (var i = 0; i < count; i++)
          row('m${i.toString().padLeft(4, '0')}', i * 1000),
      ];
      for (final mode in [
        'sorted',
        'reversed',
        'shuffled',
        'late',
        'same-ms',
      ]) {
        final rows = List<Message>.of(source);
        switch (mode) {
          case 'reversed':
            rows.setAll(0, rows.reversed.toList());
          case 'shuffled':
            rows.shuffle(random);
          case 'late':
            if (rows.length > 1) {
              final last = rows.length - 1;
              final held = rows[last];
              rows[last] = rows[last - 1];
              rows[last - 1] = held;
            }
          case 'same-ms':
            rows.setAll(0, [
              for (var i = 0; i < count; i++)
                row(
                  'm${(count - i).toString().padLeft(4, '0')}',
                  100000 + i % 1000,
                ),
            ]);
        }
        final expected = List<Message>.of(rows)
          ..sort((a, b) {
            final aMs = a.timestamp.millisecondsSinceEpoch,
                bMs = b.timestamp.millisecondsSinceEpoch;
            return aMs == bMs ? a.id.compareTo(b.id) : aMs.compareTo(bMs);
          });
        sortMessageHistory(rows);
        expect(rows, expected, reason: '$count / $mode');
      }
    }
  });

  test(
    'the next snapshot rechecks order after an append or timestamp change',
    () {
      final rows = [row('a', 1000), row('b', 2000)];
      sortMessageHistory(rows);
      rows.add(row('late', 0));
      sortMessageHistory(rows);
      expect(rows.map((m) => m.id), ['late', 'a', 'b']);
      rows[2] = row('b', -1000);
      sortMessageHistory(rows);
      expect(rows.map((m) => m.id), ['b', 'late', 'a']);
    },
  );

  test('wire milliseconds and IDs define the same order as every cursor', () {
    final rows = [row('z', 100100), row('a', 100900), row('m', 100500)];
    sortMessageHistory(rows);
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
      sortMessageHistory(rows);
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
