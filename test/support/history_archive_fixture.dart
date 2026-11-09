/// Private stand input bounds, shared by its controller and storage worker.
const minHistoryArchiveRows = 32;
const maxHistoryArchiveRows = 3000;
const defaultHistoryArchiveRows = 512;

int historyArchiveRows(String? raw) {
  final count = raw == null ? defaultHistoryArchiveRows : int.tryParse(raw);
  if (count == null ||
      count < minHistoryArchiveRows ||
      count > maxHistoryArchiveRows) {
    throw ArgumentError(
      'history archive row count must be between 32 and 3000',
    );
  }
  return count;
}
