/// A synthetic stand row, compared before reconnect can repair storage loss.
/// Null ordering in an expected row makes no promise about a provisional pair.
class CrashRetentionRow {
  const CrashRetentionRow({
    required this.id,
    required this.delivered,
    this.orderAuthor,
    this.orderSeq,
    this.bodyTag,
  });
  final String id;
  final bool delivered;
  final String? orderAuthor;
  final int? orderSeq;
  final String? bodyTag;

  factory CrashRetentionRow.fromJson(Map raw) {
    if (raw['id'] is! String ||
        raw['delivered'] is! bool ||
        (raw['orderAuthor'] != null && raw['orderAuthor'] is! String) ||
        (raw['orderSeq'] != null && raw['orderSeq'] is! int) ||
        (raw['bodyTag'] != null && raw['bodyTag'] is! String)) {
      throw const FormatException('invalid synthetic retention row');
    }
    return CrashRetentionRow(
      id: raw['id'] as String,
      delivered: raw['delivered'] as bool,
      orderAuthor: raw['orderAuthor'] as String?,
      orderSeq: raw['orderSeq'] as int?,
      bodyTag: raw['bodyTag'] as String?,
    );
  }
}

/// Exact set/metadata check. Only fixed counts escape the oracle: never an ID,
/// body or author, including on failure. Extra in-flight commits are permitted
/// only when they belong to the full source history.
Map<String, Object> crashRetentionOf({
  required List<CrashRetentionRow> expected,
  required List<CrashRetentionRow> actual,
  required Set<String> allowedIds,
}) {
  bool invalid(CrashRetentionRow row) =>
      row.id.isEmpty ||
      (row.orderAuthor == null) != (row.orderSeq == null) ||
      row.orderAuthor == '' ||
      row.bodyTag == '';
  final expectedById = {for (final row in expected) row.id: row};
  final actualById = {for (final row in actual) row.id: row};
  final missing = expectedById.keys
      .where((id) => !actualById.containsKey(id))
      .length;
  final unexpected = actualById.keys
      .where((id) => !allowedIds.contains(id))
      .length;
  final invalidExpected = expected
      .where((row) => invalid(row) || !allowedIds.contains(row.id))
      .length;
  final invalidActual = actual.where(invalid).length;
  final expectedDelivered = expectedById.values
      .where((row) => row.delivered)
      .length;
  final retainedDelivered = expectedById.values
      .where((row) => row.delivered && actualById[row.id]?.delivered == true)
      .length;
  final expectedCanonical = expectedById.values
      .where((row) => row.orderAuthor != null)
      .length;
  final retainedCanonical = expectedById.values
      .where(
        (row) =>
            row.orderAuthor != null &&
            actualById[row.id]?.orderAuthor == row.orderAuthor &&
            actualById[row.id]?.orderSeq == row.orderSeq,
      )
      .length;
  final duplicatesExpected = expected.length - expectedById.length;
  final duplicatesActual = actual.length - actualById.length;
  final expectedBodies = expectedById.values
      .where((row) => row.bodyTag != null)
      .length;
  final retainedBodies = expectedById.values
      .where(
        (row) =>
            row.bodyTag != null && actualById[row.id]?.bodyTag == row.bodyTag,
      )
      .length;
  return {
    'passed':
        expected.isNotEmpty &&
        missing == 0 &&
        unexpected == 0 &&
        invalidExpected == 0 &&
        invalidActual == 0 &&
        duplicatesExpected == 0 &&
        duplicatesActual == 0 &&
        expectedDelivered == retainedDelivered &&
        expectedCanonical == retainedCanonical &&
        expectedBodies == retainedBodies,
    'expectedRows': expected.length,
    'actualRows': actual.length,
    'retainedExpectedRows': expectedById.length - missing,
    'missingExpectedRows': missing,
    'unexpectedRows': unexpected,
    'duplicateExpectedRows': duplicatesExpected,
    'duplicateActualRows': duplicatesActual,
    'invalidExpectedRows': invalidExpected,
    'invalidActualRows': invalidActual,
    'expectedDeliveredRows': expectedDelivered,
    'retainedDeliveredRows': retainedDelivered,
    'expectedCanonicalRows': expectedCanonical,
    'retainedCanonicalRows': retainedCanonical,
    'expectedBodyRows': expectedBodies,
    'retainedBodyRows': retainedBodies,
  };
}
