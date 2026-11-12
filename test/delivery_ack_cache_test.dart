import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/delivery_ack_cache.dart';

void main() {
  test('failed effects release only the matching peer receipt', () {
    final cache = DeliveryAckCache();
    cache.remember('one', 'same-id');
    cache.remember('two', 'same-id');
    cache.forget('one', 'same-id');
    expect(cache.contains('two', 'same-id'), isTrue);
    expect(cache.remember('one', 'same-id'), isTrue);
    expect(cache.remember('two', 'same-id'), isFalse);
  });

  test('receipts are scoped to the authenticated peer', () {
    final cache = DeliveryAckCache();
    expect(cache.remember('one', 'same-id'), isTrue);
    expect(cache.remember('two', 'same-id'), isTrue);
    expect(cache.remember('one', 'same-id'), isFalse);
  });

  test(
    'receipt floods evict cold entries and retain recently repeated ACKs',
    () {
      final cache = DeliveryAckCache(capacity: 3);
      cache.remember('peer', 'cold');
      cache.remember('peer', 'hot');
      cache.remember('peer', 'third');
      expect(cache.remember('peer', 'hot'), isFalse);
      cache.remember('peer', 'fourth');
      expect(cache.contains('peer', 'cold'), isFalse);
      expect(cache.contains('peer', 'hot'), isTrue);
      expect(cache.contains('peer', 'third'), isTrue);
      expect(cache.contains('peer', 'fourth'), isTrue);
      for (var i = 0; i < 10000; i++) {
        cache.remember('peer', 'noise-$i');
      }
      expect(cache.contains('peer', 'noise-9996'), isFalse);
      expect(cache.contains('peer', 'noise-9997'), isTrue);
      expect(cache.remember('peer', 'hot'), isTrue);
    },
  );
}
