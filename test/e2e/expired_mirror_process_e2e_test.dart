@Timeout(Duration(minutes: 10))
library;

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  test(
    'expired device-journal mirrors stay out of the conversation before sweep and after TTL off',
    () async {
      final f = await ProcessFleet.start(gate);
      addTearDown(f.dispose);
      final a = f.a, b = f.b, c = f.c;
      await base.introduceProcesses(a, c);
      await base.linkProcesses(a, b);
      final ai = (await base.deviceInfo(a))['identity'] as String;
      final ci = (await base.deviceInfo(c))['identity'] as String;
      await a.checked('/disappearing', query: {'peer': ci, 'set': '30'});
      await waitUntil(
        () async =>
            (await b.checked(
                  '/disappearing',
                  query: {'peer': ci},
                ))['ttlSeconds'] ==
                30 &&
            (await c.checked(
                  '/disappearing',
                  query: {'peer': ai},
                ))['ttlSeconds'] ==
                30,
        what: 'A/B/C agree on the real thirty-second TTL before B goes offline',
      );
      await b.stop();
      const bodies = [
        'ttl-journal-expired-incoming',
        'ttl-journal-expired-outgoing',
      ];
      await c.checked('/send_message', query: {'peer': ai, 'text': bodies[0]});
      await a.checked('/send_message', query: {'peer': ci, 'text': bodies[1]});
      for (final body in bodies) {
        await base.hasBody(a, ci, body);
        await base.hasBody(c, ai, body);
      }
      final source = (await base.rows(
        a,
        ci,
      )).where((row) => bodies.contains(row['body'])).toList();
      expect(source, hasLength(2));
      expect(source.map((row) => row['id']).toSet(), hasLength(2));
      final expiry = source
          .map(
            (row) => DateTime.parse(
              row['timestamp'] as String,
            ).add(const Duration(seconds: 30)),
          )
          .reduce((a, b) => a.isAfter(b) ? a : b);
      expect(
        DateTime.now().isBefore(expiry),
        isTrue,
        reason: 'the source rows must actually be observed while live',
      );
      Future<bool> hasJournal(ProcessDevice device) async {
        final events =
            (await device.checked('/device_events'))['events'] as Map;
        return source.every((row) {
          final entry = events['msgMirror|${row['id']}'];
          return entry is Map &&
              entry['payload'] is Map &&
              (entry['payload'] as Map)['body'] == row['body'];
        });
      }

      expect(await hasJournal(a), isTrue);
      E2eLog.line('PROCESS_TTL_LIVE_SOURCE_AND_JOURNAL_CONFIRMED');
      await waitUntil(
        () => !DateTime.now().isBefore(expiry.add(const Duration(seconds: 1))),
        what: 'the real source message TTL expires while B is offline',
        timeout: const Duration(seconds: 40),
        interval: const Duration(milliseconds: 100),
      );
      await c.stop();
      await b.start();
      await waitUntil(
        () => hasJournal(b),
        what: 'the expired mirrors actually arrive in B signed device journal',
      );
      E2eLog.line('PROCESS_TTL_EXPIRED_JOURNAL_RECEIVED');
      Future<void> absentForObservation() async {
        final watch = Stopwatch()..start();
        do {
          final rows = await base.rows(b, ci);
          expect(
            rows.where((row) => source.any((s) => s['id'] == row['id'])),
            isEmpty,
            reason:
                'an expired body must never be projected, even before a background sweep',
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        } while (watch.elapsed < const Duration(seconds: 3));
      }

      await absentForObservation();
      E2eLog.line('PROCESS_TTL_EXPIRED_PROJECTIONS_ABSENT');
      await a.checked('/disappearing', query: {'peer': ci, 'set': '0'});
      await waitUntil(
        () async =>
            (await b.checked(
              '/disappearing',
              query: {'peer': ci},
            ))['ttlSeconds'] ==
            null,
        what: 'TTL-off decision is durably reflected on B',
      );
      await a.stop();
      await b.restart();
      expect(
        await hasJournal(b),
        isTrue,
        reason:
            'the replay check must exercise still-held journal mirrors, not an empty log',
      );
      await absentForObservation();
      E2eLog.line('PROCESS_TTL_NO_RESURRECTION_AFTER_OFF_AND_COLD_RESTART');
    },
    skip: gate.skip,
  );
}
