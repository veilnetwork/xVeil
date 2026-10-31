/// Bounded session receipt deduplication. Durable message status is authoritative
/// after eviction or restart; a receipt from another peer never shares a slot.
class DeliveryAckCache {
  DeliveryAckCache({this.capacity = 4096}) {
    RangeError.checkValueInInterval(capacity, 1, 1 << 20, 'capacity');
  }

  final int capacity;
  final _receipts = <(String, String)>{};

  bool contains(String peer, String id) => _receipts.contains((peer, id));

  bool remember(String peer, String id) {
    final key = (peer, id);
    final first = !_receipts.remove(key);
    _receipts.add(key);
    if (_receipts.length > capacity) _receipts.remove(_receipts.first);
    return first;
  }
}
