import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_route_delivery_observer.dart';

void main() {
  test(
    'hangup during open closes the late candidate without probing',
    () async {
      final observer = CallRouteDeliveryObserver();
      final opened = Completer<int?>();
      var owned = true;
      final closed = <int>[];
      var probes = 0;
      final pending = observer.observe(
        currentChannel: 1,
        stillOwned: () => owned,
        openAlternate: () => opened.future,
        qualify: (_) async {
          probes++;
          return true;
        },
        closeAlternate: closed.add,
        samples: 1,
      );
      owned = false;
      opened.complete(2);
      expect((await pending)['reason'], 'call_changed');
      expect(closed, [2]);
      expect(probes, 0);
    },
  );

  test(
    'route replacement during a probe retires candidate and cancels pair',
    () async {
      final observer = CallRouteDeliveryObserver();
      final qualified = Completer<bool>();
      final probing = Completer<void>();
      var owned = true;
      final calls = <int>[];
      final closed = <int>[];
      final pending = observer.observe(
        currentChannel: 1,
        stillOwned: () => owned,
        openAlternate: () async => 2,
        qualify: (channel) {
          calls.add(channel);
          probing.complete();
          return qualified.future;
        },
        closeAlternate: closed.add,
        samples: 1,
      );
      await probing.future;
      owned = false;
      qualified.complete(true);
      expect((await pending)['reason'], 'call_changed');
      expect(calls, [1]);
      expect(closed, [2]);
    },
  );

  test('simultaneous observation cannot open another candidate', () async {
    final observer = CallRouteDeliveryObserver();
    final opened = Completer<int?>();
    var opens = 0;
    Future<Map<String, Object?>> observe() => observer.observe(
      currentChannel: 1,
      stillOwned: () => true,
      openAlternate: () {
        opens++;
        return opened.future;
      },
      qualify: (_) async => false,
      closeAlternate: (_) {},
      samples: 1,
    );
    final first = observe();
    expect((await observe())['reason'], 'busy');
    expect(opens, 1);
    opened.complete(null);
    expect((await first)['reason'], 'alternate_unavailable');
    // An unavailable candidate releases ownership for a subsequent attempt.
    expect((await observe())['reason'], 'alternate_unavailable');
    expect(opens, 2);
  });

  test('error still closes candidate and permits a new observation', () async {
    final observer = CallRouteDeliveryObserver();
    final closed = <int>[];
    Future<Map<String, Object?>> observe() => observer.observe(
      currentChannel: 1,
      stillOwned: () => true,
      openAlternate: () async => 2,
      qualify: (_) async => throw StateError('private detail'),
      closeAlternate: closed.add,
      samples: 1,
    );
    expect((await observe())['reason'], 'probe_error');
    expect((await observe())['reason'], 'probe_error');
    expect(closed, [2, 2]);
  });

  test(
    'paired observations respect echo limit and failures remain unqualified',
    () async {
      final observer = CallRouteDeliveryObserver();
      final starts = <Duration>[];
      final channels = <int>[];
      final clock = Stopwatch()..start();
      final closed = <int>[];
      final result = await observer.observe(
        currentChannel: 1,
        stillOwned: () => true,
        openAlternate: () async => 2,
        qualify: (channel) async {
          starts.add(clock.elapsed);
          channels.add(channel);
          return channel == 1;
        },
        closeAlternate: closed.add,
        samples: 2,
      );
      expect(channels, [1, 2, 1, 2]);
      for (var i = 1; i < starts.length; i++) {
        expect(
          starts[i] - starts[i - 1],
          greaterThanOrEqualTo(const Duration(milliseconds: 200)),
        );
      }
      expect(result['ok'], isTrue); // observation completed, not route success
      final samples = result['samples'] as List<Map<String, Object?>>;
      for (final sample in samples) {
        expect((sample['current'] as Map)['qualified'], isTrue);
        expect((sample['alternate'] as Map)['qualified'], isFalse);
      }
      expect(closed, [2]);
    },
  );
}
