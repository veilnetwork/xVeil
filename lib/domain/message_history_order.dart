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

/// Keep a fresh snapshot which is already in wire order without re-sorting it.
/// Two sorted runs can use a buffer of at most 128 references to merge a small
/// displaced block. Other inversions take the ordinary in-place sort path.
/// No rows survive the call, and all paths use the wire's millisecond/ID order.
void sortMessageHistory(List<Message> rows) {
  if (rows.length < 2) return;
  var split = 0;
  var previous = rows.first;
  var previousMs = previous.timestamp.millisecondsSinceEpoch;
  for (var i = 1; i < rows.length; i++) {
    final current = rows[i];
    final currentMs = current.timestamp.millisecondsSinceEpoch;
    if (currentMs < previousMs ||
        (currentMs == previousMs && current.id.compareTo(previous.id) < 0)) {
      if (split != 0) {
        rows.sort(compareMessageHistoryOrder);
        return;
      }
      split = i;
    }
    previous = current;
    previousMs = currentMs;
  }
  if (split == 0) return;
  const maxBufferedRows = 128;
  if (split <= maxBufferedRows && split <= rows.length - split) {
    final held = rows.sublist(0, split);
    var left = 0, right = split, write = 0;
    while (left < held.length && right < rows.length) {
      if (compareMessageHistoryOrder(held[left], rows[right]) <= 0) {
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
      if (compareMessageHistoryOrder(rows[left], held[right]) > 0) {
        rows[write--] = rows[left--];
      } else {
        rows[write--] = held[right--];
      }
    }
    while (right >= 0) {
      rows[write--] = held[right--];
    }
  } else {
    rows.sort(compareMessageHistoryOrder);
  }
}

/// The first row strictly beyond a validated archive cursor. [rows] must be
/// sorted by [compareMessageHistoryOrder]. This reads O(log n) rows, including
/// when the cursor has disappeared after deletion or lies beyond the tail.
/// It does not filter/authorize rows or remember a previous snapshot.
int messageHistoryStartAfter(List<Message> rows, int timestampMs, String id) {
  var low = 0, high = rows.length;
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
