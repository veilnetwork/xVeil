import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'crash_retention_oracle.dart';

const _allowed = {'CANARY_a', 'CANARY_b', 'CANARY_c'};
const _a = CrashRetentionRow(
  id: 'CANARY_a',
  delivered: true,
  orderAuthor: 'CANARY_author',
  orderSeq: 7,
);
const _b = CrashRetentionRow(id: 'CANARY_b', delivered: true);
Map<String, Object> check(
  List<CrashRetentionRow> actual, {
  List<CrashRetentionRow> expected = const [_a, _b],
}) =>
    crashRetentionOf(expected: expected, actual: actual, allowedIds: _allowed);

void main() {
  test('exact rows retain delivery and already canonical positions', () {
    final result = check([_b, _a]);
    expect(result['passed'], true);
    expect(result['retainedExpectedRows'], 2);
    expect(result['retainedDeliveredRows'], 2);
    expect(result['retainedCanonicalRows'], 1);
    expect(jsonEncode(result), isNot(contains('CANARY')));
  });
  test(
    'later in-flight source commits and provisional upgrades are permitted',
    () {
      expect(
        check([
          _a,
          const CrashRetentionRow(
            id: 'CANARY_b',
            delivered: true,
            orderAuthor: 'upgraded',
            orderSeq: 8,
          ),
          const CrashRetentionRow(id: 'CANARY_c', delivered: false),
        ])['passed'],
        true,
      );
    },
  );
  test('same counts with substituted IDs cannot hide a missing row', () {
    final result = check(
      [
        const CrashRetentionRow(id: 'CANARY_a', delivered: false),
        const CrashRetentionRow(id: 'CANARY_c', delivered: false),
      ],
      expected: const [
        CrashRetentionRow(id: 'CANARY_a', delivered: false),
        CrashRetentionRow(id: 'CANARY_b', delivered: false),
      ],
    );
    expect(result['passed'], false);
    expect(result['missingExpectedRows'], 1);
  });
  test('empty equal snapshots do not prove durability', () {
    expect(check([], expected: [])['passed'], false);
  });
  test('duplicates and unknown IDs are rejected without exporting them', () {
    for (final rows in [
      [_a, _a, _b],
      [_a, _b, const CrashRetentionRow(id: 'CANARY_foreign', delivered: false)],
    ]) {
      final result = check(rows);
      expect(result['passed'], false);
      expect(jsonEncode(result), isNot(contains('CANARY')));
    }
    expect(check([_a, _b], expected: [_a, _a, _b])['passed'], false);
  });
  test('delivery cannot regress before any network repair', () {
    final result = check([
      _a,
      const CrashRetentionRow(id: 'CANARY_b', delivered: false),
    ]);
    expect(result['passed'], false);
    expect(result['retainedDeliveredRows'], 1);
  });
  test('same IDs and metadata cannot hide changed content', () {
    final original = const CrashRetentionRow(
      id: 'CANARY_a',
      delivered: true,
      bodyTag: 'CANARY_original_content',
    );
    for (final tag in [null, 'CANARY_changed_content']) {
      final result = check(
        [CrashRetentionRow(id: 'CANARY_a', delivered: true, bodyTag: tag)],
        expected: [original],
      );
      expect(result['passed'], false);
      expect(result['retainedBodyRows'], 0);
      expect(jsonEncode(result), isNot(contains('CANARY')));
    }
    expect(check([original], expected: [original])['passed'], true);
  });
  test('known canonical author and sequence cannot regress', () {
    for (final row in [
      const CrashRetentionRow(id: 'CANARY_a', delivered: true),
      const CrashRetentionRow(
        id: 'CANARY_a',
        delivered: true,
        orderAuthor: 'wrong',
        orderSeq: 7,
      ),
      const CrashRetentionRow(
        id: 'CANARY_a',
        delivered: true,
        orderAuthor: 'CANARY_author',
        orderSeq: 8,
      ),
    ]) {
      final result = check([row, _b]);
      expect(result['passed'], false);
      expect(result['retainedCanonicalRows'], 0);
    }
  });
  test('malformed expected or actual positions fail closed', () {
    for (final row in [
      const CrashRetentionRow(id: '', delivered: true),
      const CrashRetentionRow(id: 'CANARY_a', delivered: true, bodyTag: ''),
      const CrashRetentionRow(
        id: 'CANARY_a',
        delivered: true,
        orderAuthor: 'partial',
      ),
      const CrashRetentionRow(id: 'CANARY_a', delivered: true, orderSeq: 7),
      const CrashRetentionRow(
        id: 'CANARY_a',
        delivered: true,
        orderAuthor: '',
        orderSeq: 7,
      ),
    ]) {
      expect(check([row, _b])['passed'], false);
      expect(check([_a, _b], expected: [row, _b])['passed'], false);
    }
    expect(
      check(
        [_a, _b],
        expected: const [
          CrashRetentionRow(id: 'CANARY_foreign', delivered: true),
        ],
      )['passed'],
      false,
    );
  });
  test('private witness decoder rejects invalid primitive shapes', () {
    for (final value in [
      {'id': 9, 'delivered': true},
      {'id': 'CANARY_a', 'delivered': 'yes'},
      {'id': 'CANARY_a', 'delivered': true, 'orderSeq': '7'},
    ]) {
      expect(() => CrashRetentionRow.fromJson(value), throwsFormatException);
    }
  });
}
