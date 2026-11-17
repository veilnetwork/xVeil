import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/state/network_observation.dart';
import 'package:xveil/state/network_reconnect.dart';

class _Connectivity implements Connectivity {
  final events = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );
  Future<List<ConnectivityResult>> Function() read = () async => [
    ConnectivityResult.wifi,
  ];
  @override
  Future<List<ConnectivityResult>> checkConnectivity() => read();
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => events.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = 'xveil/default_network';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Connectivity connectivity;
  late NetworkObservationSource source;
  late Future<Object?> Function() current;
  late List<String> streamCalls;

  Future<void> flush() => Future<void>.delayed(Duration.zero);
  Future<void> event(String kind, int revision) async {
    await messenger.handlePlatformMessage(
      '$channel/events',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'kind': kind,
        'revision': revision,
      }),
      (_) {},
    );
    await flush();
  }

  setUp(() {
    connectivity = _Connectivity();
    current = () async => {'kind': 'wifi', 'revision': 1};
    streamCalls = [];
    messenger.setMockMethodCallHandler(
      const MethodChannel(channel),
      (_) => current(),
    );
    messenger.setMockMethodCallHandler(const MethodChannel('$channel/events'), (
      call,
    ) async {
      streamCalls.add(call.method);
      return null;
    });
    source = NetworkObservationSource(connectivity, isAndroid: true);
  });
  tearDown(() async {
    await source.dispose();
    await connectivity.events.close();
    messenger.setMockMethodCallHandler(const MethodChannel(channel), null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('$channel/events'),
      null,
    );
  });

  test(
    'replacement during IPC retains newest revision without overlapping notifications',
    () async {
      final gate = Completer<void>();
      final attempts = <int>[];
      var inFlight = 0;
      final observer = NetworkReconnect.observations(
        current: source.current,
        changes: source.changes,
        notify: (_, revision) async {
          expect(++inFlight, 1);
          attempts.add(revision);
          if (attempts.length == 1) await gate.future;
          inFlight--;
        },
      );
      await observer.start();
      await event('wifi', 2);
      await event('wifi', 3);
      await event('wifi', 3);
      expect(attempts, [1]);
      gate.complete();
      await flush();
      expect(attempts, [1, 3]);
      await observer.dispose();
    },
  );

  test(
    'late native snapshot cannot overwrite a newer default network',
    () async {
      final query = Completer<Object?>();
      current = () => query.future;
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect.observations(
        current: source.current,
        changes: source.changes,
        notify: (attachment, _) async => observed.add(attachment),
      );
      final starting = observer.start();
      await flush();
      await event('cellular', 2);
      query.complete({'kind': 'wifi', 'revision': 1});
      await starting;
      expect(observed, [NetworkAttachment.cellular]);
      await observer.dispose();
    },
  );

  test(
    'native observation is authoritative over duplicate legacy type events',
    () async {
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect.observations(
        current: source.current,
        changes: source.changes,
        notify: (attachment, _) async => observed.add(attachment),
      );
      await observer.start();
      connectivity.events.add([ConnectivityResult.mobile]);
      await flush();
      expect(observed, [NetworkAttachment.wifi]);
      await event('cellular', 2);
      await event('cellular', 2);
      expect(observed, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
      await observer.dispose();
    },
  );

  test(
    'native refusal retains legacy observation and bounded retry semantics',
    () async {
      current = () async =>
          throw PlatformException(code: 'network_observation');
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect.observations(
        current: source.current,
        changes: source.changes,
        notify: (attachment, _) async => observed.add(attachment),
      );
      await observer.start();
      await flush();
      connectivity.events.add([ConnectivityResult.mobile]);
      await flush();
      expect(observed, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
      expect(streamCalls, contains('cancel'));
      await observer.dispose();
    },
  );

  test(
    'dispose cancels the native subscription and discards queued events',
    () async {
      final received = <NetworkObservation>[];
      final subscription = source.changes.listen(received.add);
      await flush();
      await event('wifi', 1);
      await source.dispose();
      await event('cellular', 2);
      expect(received, hasLength(1));
      expect(streamCalls, ['listen', 'cancel']);
      await subscription.cancel();
    },
  );

  test('late fallback seed cannot regress a newer legacy event', () async {
    final received = <NetworkAttachment>[];
    final subscription = source.changes.listen(
      (value) => received.add(value.attachment),
    );
    await source.current();
    final query = Completer<List<ConnectivityResult>>();
    connectivity.read = () => query.future;
    await messenger.handlePlatformMessage(
      '$channel/events',
      const StandardMethodCodec().encodeErrorEnvelope(
        code: 'network_observation',
      ),
      (_) {},
    );
    await flush();
    connectivity.events.add([ConnectivityResult.mobile]);
    query.complete([ConnectivityResult.wifi]);
    await flush();
    expect(received, [NetworkAttachment.cellular]);
    await subscription.cancel();
  });

  test('the wire accepts only a category and a nonnegative local revision', () {
    for (final bad in [
      null,
      {},
      {'kind': 'wifi'},
      {'kind': 'wifi', 'revision': -1},
      {'kind': 'secret-canary', 'revision': 1},
      {'kind': 'wifi', 'revision': 'secret-canary'},
    ]) {
      expect(() => NetworkObservation.decode(bad), throwsFormatException);
    }
    final value = NetworkObservation.decode({'kind': 'wifi', 'revision': 2});
    expect(value.attachment, NetworkAttachment.wifi);
    expect(value.revision, 2);
  });
}
