import 'chat.dart';
import 'message_history_order.dart';

/// A wire-order index of storage keys, without retained messages or verdicts.
/// The owner must invalidate it whenever stored row membership/coordinates change and
/// supply the current row lookup under the same storage read gate. It does
/// not filter expiry/retention or establish authorization.
class MessageHistoryKeyIndex {
  MessageHistoryKeyIndex(Iterable<String> keys, Message Function(String) read)
    : _keys = keys.toList() {
    sortMessageHistoryKeys(_keys, read);
  }

  final List<String> _keys;

  List<Message> window(
    Message Function(String) read, {
    required int limit,
    int? afterTimestampMs,
    String? afterId,
  }) {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    if ((afterTimestampMs == null) != (afterId == null)) {
      throw ArgumentError('history cursor requires both timestamp and id');
    }
    if (limit == 0) return [];
    var low = 0, high = _keys.length;
    if (afterTimestampMs != null) {
      while (low < high) {
        final middle = low + ((high - low) >> 1);
        if (compareMessageHistoryCursor(
              read(_keys[middle]),
              afterTimestampMs,
              afterId!,
            ) <=
            0) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
    }
    final count = (_keys.length - low).clamp(0, limit);
    return [for (var i = low; i < low + count; i++) read(_keys[i])];
  }
}
