import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/diagnostic_background.dart';
import 'package:xveil/core/diagnostic_journal.dart';

class _Private {
  @override
  String toString() => throw StateError('private object must stay unread');
}

void main() {
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
