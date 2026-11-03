@Timeout(Duration(minutes: 8))
library;

import 'package:flutter_test/flutter_test.dart';

import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;
import 'offline_backlog_process_e2e_test.dart' as observer;

void main() {
  final gate = E2eGate.read();
  test(
    'live storage observer preserves own and peer author perspectives',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      await base.introduceProcesses(fleet.a, fleet.c);
      await base.linkProcesses(fleet.a, fleet.b);
      final ai = (await base.deviceInfo(fleet.a))['identity'] as String;
      final ci = (await base.deviceInfo(fleet.c))['identity'] as String;
      final physical = (await base.deviceInfo(fleet.a))['nodeId'] as String;
      await fleet.a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'observer-preflight'},
      );
      final source = (await observer.rows(
        fleet.a,
        ci,
        const {},
      )).singleWhere((row) => row['body'] == 'observer-preflight');
      final id = source['id'];
      expect(source['orderAuthor'], physical);
      expect(source['orderSeq'], isA<int>());
      await waitUntil(
        () async {
          final rows = await observer.rows(fleet.c, ai, const {});
          final matches = rows.where((row) => row['id'] == id).toList();
          if (matches.isEmpty) return false;
          expect(matches, hasLength(1));
          expect(matches.single['body'], source['body']);
          expect(matches.single['orderAuthor'], ai);
          expect(matches.single['orderSeq'], source['orderSeq']);
          return true;
        },
        what: 'C files the same message under its authenticated peer identity',
      );
      await waitUntil(() async {
        final rows = await observer.rows(fleet.b, ci, const {});
        final matches = rows.where((row) => row['id'] == id).toList();
        if (matches.isEmpty) return false;
        expect(matches, hasLength(1));
        return matches.single['body'] == source['body'] &&
            matches.single['orderAuthor'] == source['orderAuthor'] &&
            matches.single['orderSeq'] == source['orderSeq'] &&
            matches.single['status'] == 'delivered';
      }, what: 'B retains the original device position and final delivery');
    },
    skip: gate.skip,
  );
}
