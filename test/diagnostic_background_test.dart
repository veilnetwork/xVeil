import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/diagnostic_background.dart';
import 'package:xveil/core/diagnostic_journal.dart';

class _Private {
  @override
  String toString() => throw StateError('private object must stay unread');
}

void main() {
  test('network snapshot exports only boolean flags and bounded policy', () {
    final journal = DiagnosticJournal(enabled: true);
    journal.recordBackgroundState({
      'networkSnapshotAvailable': true,
      'networkPresent': true,
      'networkCapabilitiesAvailable': true,
      'networkMetered': true,
      'processNetworkBound': false,
      'processNetworkIsDefault': _Private(),
      'networkWifi': false,
      'networkCellular': true,
      'networkVpn': false,
      'networkInternet': true,
      'networkValidated': true,
      'networkNotSuspended': true,
      'restrictBackgroundStatus': 3,
      'networkHandle': 314159265,
      'uid': 314159265,
      'ssid': 'private-canary',
      'interface': _Private(),
      'addresses': ['192.0.2.1'],
    });
    final row = (journal.toJson()['events'] as List).single as Map;
    expect(row['values'], {
      'supported': 1,
      'success': 1,
      'networkSnapshotAvailable': 1,
      'networkPresent': 1,
      'networkCapabilitiesAvailable': 1,
      'networkMetered': 1,
      'processNetworkBound': 0,
      'networkWifi': 0,
      'networkCellular': 1,
      'networkVpn': 0,
      'networkInternet': 1,
      'networkValidated': 1,
      'networkNotSuspended': 1,
      'restrictBackgroundStatus': 3,
    });
    final json = jsonEncode(journal.toJson());
    for (final private in ['private-canary', '314159265', '192.0.2.1']) {
      expect(json, isNot(contains(private)));
    }
    for (final value in <Object?>[0, 4, -1, 314159265, 2.5, '2', _Private()]) {
      journal.clear();
      journal.recordBackgroundState({
        'restrictBackgroundStatus': value,
        'networkPresent': value,
      });
      final invalid = (journal.toJson()['events'] as List).single as Map;
      expect(invalid['values'], {'supported': 1, 'success': 1});
    }
    for (final policy in [1, 2, 3]) {
      journal.clear();
      journal.recordBackgroundState({'restrictBackgroundStatus': policy});
      final valid = (journal.toJson()['events'] as List).single as Map;
      expect(valid['values'], containsPair('restrictBackgroundStatus', policy));
    }
  });

  test('handover sampling coalesces and retains native slot after timeout', () {
    fakeAsync((clock) {
      final journal = DiagnosticJournal(enabled: true);
      final gate = Completer<Map<Object?, Object?>?>();
      var reads = 0;
      final sampler = DiagnosticBackgroundSampler(
        journal: journal,
        readState: () {
          reads++;
          return reads == 1 ? gate.future : Future.value({'networkVpn': false});
        },
      );
      sampler.request();
      for (var n = 0; n < 50; n++) {
        sampler.request();
      }
      clock.flushMicrotasks();
      expect(reads, 1);
      clock.elapse(const Duration(seconds: 1));
      final timedOut = (journal.toJson()['events'] as List).single as Map;
      expect(timedOut['values'], {'success': 0});
      sampler.request();
      clock.elapse(const Duration(minutes: 1));
      expect(reads, 1, reason: 'timed-out native read still owns the slot');
      gate.complete({'networkWifi': true});
      clock.flushMicrotasks();
      expect(
        reads,
        2,
        reason: 'one coalesced follow-up observes current state',
      );
      final events = journal.toJson()['events'] as List;
      expect(events, hasLength(2));
      expect((events.last as Map)['values'], {
        'supported': 1,
        'success': 1,
        'networkVpn': 0,
      });
      sampler.dispose();
      sampler.request();
      clock.flushMicrotasks();
      expect(reads, 2);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('disabled and disposed samplers do not start queued OS reads', () {
    fakeAsync((clock) {
      var reads = 0;
      final disabled = DiagnosticBackgroundSampler(
        journal: DiagnosticJournal(enabled: false),
        readState: () async {
          reads++;
          return null;
        },
      );
      disabled.request();
      clock.flushMicrotasks();
      expect(reads, 0);
      final gate = Completer<Map<Object?, Object?>?>();
      final enabled = DiagnosticBackgroundSampler(
        journal: DiagnosticJournal(enabled: true),
        readState: () {
          reads++;
          return gate.future;
        },
      );
      enabled.request();
      enabled.request();
      enabled.dispose();
      gate.completeError(StateError('private-canary'));
      clock.flushMicrotasks();
      expect(reads, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('malformed volume cannot smuggle identifiers into the report', () {
    for (final value in <Object?>[
      -1,
      101,
      1793000000000,
      60.5,
      'private-canary',
      _Private(),
    ]) {
      final journal = DiagnosticJournal(enabled: true);
      journal.recordBackgroundState({'callVolumePercent': value});
      final row = (journal.toJson()['events'] as List).single as Map;
      expect(row['values'], {'supported': 1, 'success': 1});
    }
  });
  test('disabled reports never probe the OS', () async {
    final journal = DiagnosticJournal(enabled: false);
    await sampleDiagnosticBackgroundState(
      journal: journal,
      readState: () async => throw StateError('must not reach the channel'),
    );
    expect(journal.toJson()['events'], isEmpty);
    expect(journal.toJson()['counts'], isEmpty);
  });

  test('OS export is a boolean allowlist and survives busy traffic', () async {
    final journal = DiagnosticJournal(enabled: true, capacity: 1);
    await sampleDiagnosticBackgroundState(
      journal: journal,
      readState: () async => {
        'serviceForeground': true,
        'wakeLockHeld': false,
        'interactive': true,
        'deviceIdle': false,
        'batteryExempt': true,
        'backgroundRestricted': false,
        'powerSave': _Private(),
        'hostname': 'private-canary',
        'notification': _Private(),
        'uid': 123456789,
        'systemMicMuted': false,
        'callVolumePercent': 60,
      },
    );
    journal.record(DiagnosticEvent.transportReceived);
    final retained = journal.toJson()['last_evidence'] as Map;
    final row = retained['backgroundSnapshot'] as Map;
    expect(row['values'], {
      'supported': 1,
      'success': 1,
      'serviceForeground': 1,
      'wakeLockHeld': 0,
      'interactive': 1,
      'deviceIdle': 0,
      'batteryExempt': 1,
      'backgroundRestricted': 0,
      'systemMicMuted': 0,
      'callVolumePercent': 60,
    });
    final json = jsonEncode(journal.toJson());
    expect(json, isNot(contains('private')));
    expect(json, isNot(contains('123456789')));
    (row['values'] as Map)['wakeLockHeld'] = 1;
    expect(
      ((journal.toJson()['last_evidence'] as Map)['backgroundSnapshot']
          as Map)['values'],
      containsPair('wakeLockHeld', 0),
    );
    journal.clear();
    expect(journal.toJson()['last_evidence'], isEmpty);
  });

  test(
    'unsupported and refused probes stay distinct without exception text',
    () async {
      final journal = DiagnosticJournal(enabled: true);
      await sampleDiagnosticBackgroundState(
        journal: journal,
        readState: () async => null,
      );
      await sampleDiagnosticBackgroundState(
        journal: journal,
        readState: () async => throw PlatformException(
          code: 'private-canary',
          message: '/Users/secret',
        ),
      );
      final events = journal.toJson()['events'] as List;
      expect((events.first as Map)['values'], {'supported': 0, 'success': 1});
      expect((events.last as Map)['values'], {'success': 0});
      expect(jsonEncode(journal.toJson()), isNot(contains('private-canary')));
      expect(jsonEncode(journal.toJson()), isNot(contains('/Users')));
    },
  );
}
