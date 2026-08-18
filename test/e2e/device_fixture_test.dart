@Timeout(Duration(minutes: 25))
library;

import 'package:flutter_test/flutter_test.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

/// Smoke test for the DEVICE half of the harness, separate from any case.
///
/// Same reason as `relay_cluster_test.dart`: "the app stack never came up",
/// "the two devices never linked" and "the state did not converge" are three
/// different failures that a case reports identically. When this file is green
/// and a case is red, the fixture is not the suspect.
void main() {
  final gate = E2eGate.read();

  group('device fixture', () {
    test('one device boots the REAL app wiring and comes back after a restart',
        () async {
      E2eFleet? fleet;
      addTearDown(() async => fleet?.dispose());
      fleet = await E2eFleet.start(gate: gate, labels: const ['A']);
      final a = fleet.a;

      expect(
        a.groups,
        isNotNull,
        reason: 'groupServiceProvider must build — it is where the multi-device '
            'mirror and the device-sync bridge are wired, and a null one means '
            'this harness proves nothing about either',
      );
      // The master device derives its node key from the phrase and then carries
      // a sovereign identity, so the two ids it answers to are DIFFERENT
      // numbers. Equal ids is the signature of a degenerate document — the
      // failure this project has hit five separate times.
      expect(a.identityNodeId.hex, hasLength(64));
      expect(a.deviceNodeId.hex, hasLength(64));

      final before = await a.snapshot();
      expect(before.deviceGroupIdHex, isNull,
          reason: 'a device that has never linked has no device group');

      await a.restart();
      expect(a.groups, isNotNull, reason: 'the restart lost the app wiring');
      final after = await a.snapshot();
      expect(after.notes['deviceNode'], before.notes['deviceNode'],
          reason: 'the node identity must survive a restart — a device that '
              'mints a new one on every boot is a new device each time');
    }, skip: gate.skip);

    test('A and B link into one identity and the oracle sees one device group',
        () async {
      E2eFleet? fleet;
      addTearDown(() async => fleet?.dispose());
      fleet = await E2eFleet.start(gate: gate, labels: const ['A', 'B']);
      final f = fleet;

      expect(
        f.a.identityNodeId.hex,
        isNot(f.b.identityNodeId.hex),
        reason: 'before the link, B is its own identity',
      );

      await f.linkDevice(master: f.a, target: f.b);

      final a = await f.a.snapshot();
      final b = await f.b.snapshot();
      expect(a.deviceGroupIdHex, isNotNull, reason: 'A: $a');
      expect(b.deviceGroupIdHex, a.deviceGroupIdHex,
          reason: 'B did not adopt A\'s device group\nA=$a\nB=$b\n'
              '${await f.diagnostics()}');
      expect(a.memberCount, greaterThanOrEqualTo(2),
          reason: 'the device group must name both devices: $a');
    }, skip: gate.skip);
  });
}
