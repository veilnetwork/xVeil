import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/api_server.dart';
import 'package:xveil/api/webhook_pump.dart';

/// The webhook target is a URL the operator configures — not necessarily one
/// that behaves. Two ways that used to cost the daemon unboundedly (audit
/// XV-09): a response whose body never ends, and an event stream that outruns
/// delivery.
void main() {
  group('one deadline covers the whole exchange', () {
    late HttpServer server;

    tearDown(() async => server.close(force: true));

    test('a body that never ends does not hold the push open', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        // Headers promptly, then dribble forever. The old timeout covered
        // `req.close()` and stopped there, leaving `drain()` unbounded.
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.text;
        Timer.periodic(const Duration(milliseconds: 20), (t) {
          try {
            req.response.write('.');
          } catch (_) {
            t.cancel();
          }
        });
      });

      final stopwatch = Stopwatch()..start();
      final ok = await pushWebhookEvent(
        'http://${server.address.address}:${server.port}/hook',
        {'type': 'test'},
        timeout: const Duration(milliseconds: 300),
      );
      stopwatch.stop();

      expect(ok, isFalse, reason: 'a push that timed out was not delivered');
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'the deadline must cover the body, not just the headers',
      );
    });
  });

  group('the queue is bounded and drained by one worker', () {
    Stream<Map<String, dynamic>> noEvents() => const Stream.empty();

    test('a target that hangs cannot pile up deliveries', () async {
      final pump = WebhookPump(noEvents);
      var inFlight = 0;
      var maxInFlight = 0;
      final gate = Completer<void>();

      pump.deliver = (target, event) async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await gate.future;
        inFlight--;
      };
      await pump.setTarget('http://example.invalid/hook');

      // More events than the queue holds, all while the first delivery is
      // still stuck.
      for (var i = 0; i < WebhookPump.queueCap + 50; i++) {
        pump.enqueueForTest({'type': 'e$i'});
      }
      await Future<void>.delayed(Duration.zero);

      expect(
        maxInFlight,
        1,
        reason: 'one worker — a slow target costs latency, not sockets',
      );
      expect(
        pump.queueLengthForTest,
        lessThanOrEqualTo(WebhookPump.queueCap),
        reason: 'the queue must not grow with the event stream',
      );

      gate.complete();
      await pump.close();
    });

    test('close stops the pump and drops what is queued', () async {
      final pump = WebhookPump(noEvents);
      pump.deliver = (target, event) async {};
      await pump.setTarget('http://example.invalid/hook');
      pump.enqueueForTest({'type': 'a'});
      await pump.close();
      expect(pump.queueLengthForTest, 0);
    });
  });
}
