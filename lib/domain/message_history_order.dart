import 'chat.dart';

/// Archive positions use the wire's millisecond timestamp and then message ID.
/// Storage implementations may retain finer timestamps; those extra digits
/// must not disagree with the cursor order seen by a receiving device.
int compareMessageHistoryOrder(Message a, Message b) =>
    compareMessageHistoryCursor(a, b.timestamp.millisecondsSinceEpoch, b.id);

int compareMessageHistoryCursor(Message message, int timestampMs, String id) {
  final time = message.timestamp.millisecondsSinceEpoch.compareTo(timestampMs);
  return time != 0 ? time : message.id.compareTo(id);
}

// Zero for an ordered view, the split of two ordered runs, or -1 for more.
// This is a fresh observation, not a remembered assertion about a store.
int _historyRunSplit<T>(List<T> rows, Message Function(T) read) {
  if (rows.length < 2) return 0;
  var split = 0;
  var previous = read(rows.first);
  var previousMs = previous.timestamp.millisecondsSinceEpoch;
  for (var i = 1; i < rows.length; i++) {
    final current = read(rows[i]);
    final currentMs = current.timestamp.millisecondsSinceEpoch;
    if (currentMs < previousMs ||
        (currentMs == previousMs && current.id.compareTo(previous.id) < 0)) {
      if (split != 0) return -1;
      split = i;
    }
    previous = current;
    previousMs = currentMs;
  }
  return split;
}

/// Keep a fresh snapshot which is already in wire order without re-sorting it.
/// Two sorted runs can use a buffer of at most 128 references to merge a small
/// displaced block. Other inversions take the ordinary in-place sort path.
/// No rows survive the call, and all paths use the wire's millisecond/ID order.
void sortMessageHistory(List<Message> rows) =>
    _sortHistoryRows(rows, (message) => message);

/// Same wire order/run handling for a storage-key index. Row lookups are
/// synchronous and are not retained beyond this sort.
void sortMessageHistoryKeys(List<String> keys, Message Function(String) read) =>
    _sortHistoryRows(keys, read);

void _sortHistoryRows<T>(List<T> rows, Message Function(T) read) {
  int compare(T a, T b) => compareMessageHistoryOrder(read(a), read(b));
  final split = _historyRunSplit(rows, read);
  if (split == 0) return;
  if (split < 0) {
    rows.sort(compare);
    return;
  }
  const maxBufferedRows = 128;
  if (split <= maxBufferedRows && split <= rows.length - split) {
    final held = rows.sublist(0, split);
    var left = 0, right = split, write = 0;
    while (left < held.length && right < rows.length) {
      if (compare(held[left], rows[right]) <= 0) {
        rows[write++] = held[left++];
      } else {
        rows[write++] = rows[right++];
      }
    }
    while (left < held.length) {
      rows[write++] = held[left++];
    }
  } else if (rows.length - split <= maxBufferedRows) {
    final held = rows.sublist(split);
    var left = split - 1, right = held.length - 1, write = rows.length - 1;
    while (left >= 0 && right >= 0) {
      if (compare(rows[left], held[right]) > 0) {
        rows[write--] = rows[left--];
      } else {
        rows[write--] = held[right--];
      }
    }
    while (right >= 0) {
      rows[write--] = held[right--];
    }
  } else {
    rows.sort(compare);
  }
}

/// The first row strictly beyond a validated archive cursor. [rows] must be
/// sorted by [compareMessageHistoryOrder]. This reads O(log n) rows, including
/// when the cursor has disappeared after deletion or lies beyond the tail.
/// It does not filter/authorize rows or remember a previous snapshot.
int messageHistoryStartAfter(List<Message> rows, int timestampMs, String id) =>
    _historyStartAfterRange(rows, timestampMs, id, 0, rows.length);

int _historyStartAfterRange(
  List<Message> rows,
  int timestampMs,
  String id,
  int low,
  int high,
) {
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (compareMessageHistoryCursor(rows[middle], timestampMs, id) <= 0) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// Select at most [limit] rows from one fresh view, strictly beyond the cursor.
/// One/two sorted runs need only a fresh order scan, bounded binary lookups
/// and the requested merge window. Other layouts retain the ordinary sort on
/// a detached copy. Never mutates input or retains rows for the next request.
/// This neither filters visibility nor establishes authorization; callers keep
/// those checks and independent wire row/byte limits.
List<Message> messageHistoryWindow(
  List<Message> rows, {
  required int limit,
  int? afterTimestampMs,
  String? afterId,
}) {
  if (limit < 0) throw ArgumentError.value(limit, 'limit');
  if ((afterTimestampMs == null) != (afterId == null)) {
    throw ArgumentError('history cursor requires both timestamp and id');
  }
  if (limit == 0 || rows.isEmpty) return [];
  int startIn(List<Message> source, int low, int high) =>
      afterTimestampMs == null
      ? low
      : _historyStartAfterRange(source, afterTimestampMs, afterId!, low, high);
  List<Message> bounded(List<Message> source, int start) {
    final count = (source.length - start).clamp(0, limit);
    return source.getRange(start, start + count).toList();
  }

  final split = _historyRunSplit(rows, (message) => message);
  if (split == 0) return bounded(rows, startIn(rows, 0, rows.length));
  if (split < 0) {
    final sorted = List<Message>.of(rows)..sort(compareMessageHistoryOrder);
    return bounded(sorted, startIn(sorted, 0, sorted.length));
  }
  var left = startIn(rows, 0, split);
  var right = startIn(rows, split, rows.length);
  final out = <Message>[];
  while (out.length < limit && (left < split || right < rows.length)) {
    if (left == split) {
      out.add(rows[right++]);
    } else if (right == rows.length ||
        compareMessageHistoryOrder(rows[left], rows[right]) <= 0) {
      out.add(rows[left++]);
    } else {
      out.add(rows[right++]);
    }
  }
  return out;
}
