import 'package:xveil/domain/chat.dart';

/// Private stand input bounds, shared by its controller and storage worker.
const minHistoryArchiveRows = 32;
const maxHistoryArchiveRows = 100000;
const maxHistoryArchiveWireRecords = 262144;
const defaultHistoryArchiveRows = 512;

/// Keep physical setup identical when comparing production publication limits.
/// This is deliberately independent of preparedMessageBatchMaxRows.
int historyArchiveSeedBatchRows(int rows) {
  if (rows < minHistoryArchiveRows || rows > maxHistoryArchiveRows) {
    throw ArgumentError('invalid archive count');
  }
  return rows > 10000 ? 64 : 16;
}

int historyArchiveRows(String? raw) {
  final count = raw == null ? defaultHistoryArchiveRows : int.tryParse(raw);
  if (count == null ||
      count < minHistoryArchiveRows ||
      count > maxHistoryArchiveRows) {
    throw ArgumentError(
      'history archive row count must be between 32 and 100000',
    );
  }
  return count;
}

/// Optional selected row for a process crash; zero belongs to the separate
/// before-first-apply case. It must leave a nonempty suffix to recover.
int? historyCrashRow(String? raw, int rows) {
  if (raw == null) return null;
  final index = int.tryParse(raw);
  if (index == null || index <= 0 || index >= rows) {
    throw ArgumentError('history crash row must be inside the archive');
  }
  return index;
}

/// Setup-only census of the actual fold order. Fixed count/boolean fields,
/// independent of the product's comparator; never exports IDs or timestamps.
Map<String, Object> historyArchiveOrderShape(List<Message> rows) {
  var breaks = 0, firstRun = rows.length;
  for (var i = 1; i < rows.length; i++) {
    final left = rows[i - 1], right = rows[i];
    final a = left.timestamp.millisecondsSinceEpoch;
    final b = right.timestamp.millisecondsSinceEpoch;
    if (a > b || (a == b && left.id.compareTo(right.id) > 0)) {
      breaks++;
      if (breaks == 1) firstRun = i;
    }
  }
  final secondRun = breaks == 1 ? rows.length - firstRun : 0;
  return {
    'rows': rows.length,
    'descendingPairs': breaks,
    'firstRunRows': firstRun,
    'secondRunRows': secondRun,
    'fullyOrdered': breaks == 0,
    'twoRunsWithBoundedSide':
        breaks == 1 && (firstRun <= 128 || secondRun <= 128),
  };
}
