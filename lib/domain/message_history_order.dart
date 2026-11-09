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
