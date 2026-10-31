import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/diagnostic_audio_output.dart';
import 'package:xveil/core/diagnostic_journal.dart';

const active = <Object?, Object?>{
  'schema': 'xveil-audio-output/1',
  'success': true,
  'sessionState': 1,
  'outputVolumePercent': 56,
  'outputMuted': false,
  'appVolumePercent': 100,
  'appMuted': false,
  'usesDefaultOutput': true,
  'usesCommunicationsOutput': true,
  'defaultOutputsSame': true,
};

class _Private {
  @override
  String toString() => throw StateError('must never stringify');
}

Map evidence(DiagnosticJournal journal, String kind) =>
    ((journal.toJson()['last_evidence'] as Map)[kind] as Map)['values'] as Map;

void main() {
  test(
    'reader errors retain no exception data and do not poison the next read',
    () async {
      final journal = DiagnosticJournal(enabled: true);
      var reads = 0;
      final sampler = DiagnosticAudioOutputSampler(
        journal: journal,
        windows: true,
        readState: () async {
          if (++reads == 1) throw _Private();
          return active;
        },
      );
      await sampler.sample();
      expect(evidence(journal, 'audioOutputSnapshot')['success'], 0);
      await sampler.sample();
      expect(reads, 2);
      expect(evidence(journal, 'audioOutputSnapshot')['success'], 1);
    },
  );

  test('late probe after hangup cannot overwrite in-call evidence', () async {
    final journal = DiagnosticJournal(enabled: true);
    journal.recordAudioOutputState(active, duringCall: true);
    final pending = Completer<Map<Object?, Object?>?>();
    var current = true;
    final sampler = DiagnosticAudioOutputSampler(
      journal: journal,
      windows: true,
      readState: () => pending.future,
    );
    final sample = sampler.sample(
      duringCall: true,
      stillCurrent: () => current,
    );
    current = false;
    pending.complete(const {
      'schema': 'xveil-audio-output/1',
      'success': true,
      'sessionState': 0,
    });
    await sample;
    expect(evidence(journal, 'callAudioOutput')['appAudioSessionState'], 1);
    expect(evidence(journal, 'callAudioOutput')['outputVolumePercent'], 56);
  });

  test(
    'failed startup evidence survives a call ending before its first stats tick',
    () {
      final journal = DiagnosticJournal(enabled: true, capacity: 1);
      journal.recordAudioStart(
        success: false,
        stats: {
          'audio_capture_start_result': 1,
          'audio_playout_start_result': 0,
          'deviceLabel': _Private(),
          'rawLog': _Private(),
          'pid': 123456789,
        },
      );
      journal.record(DiagnosticEvent.transportSent);
      expect(evidence(journal, 'audioStart'), {
        'success': 0,
        'audioCaptureStartResult': 1,
        'audioPlayoutStartResult': 0,
      });
      journal.recordAudioStart(
        success: false,
        stats: {
          'audio_capture_start_result': '0',
          'audio_playout_start_result': 42,
        },
      );
      expect(evidence(journal, 'audioStart'), {'success': 0});
    },
  );

  test('ordinary builds and non-Windows never invoke the reader', () async {
    for (final enabled in [false, true]) {
      for (final windows in [false, true]) {
        var reads = 0;
        final sampler = DiagnosticAudioOutputSampler(
          journal: DiagnosticJournal(enabled: enabled),
          windows: windows,
          readState: () async {
            reads++;
            return active;
          },
        );
        await sampler.sample();
        expect(reads, enabled && windows ? 1 : 0);
      }
    }
  });

  test(
    'post-call export cannot overwrite the last in-call mixer state',
    () async {
      final journal = DiagnosticJournal(enabled: true, capacity: 1);
      var response = active;
      final sampler = DiagnosticAudioOutputSampler(
        journal: journal,
        windows: true,
        readState: () async => response,
      );
      await sampler.sample(duringCall: true);
      response = const {
        'schema': 'xveil-audio-output/1',
        'success': true,
        'sessionState': 0,
      };
      await sampler.sample();
      expect(evidence(journal, 'callAudioOutput')['appAudioSessionState'], 1);
      expect(evidence(journal, 'callAudioOutput')['outputVolumePercent'], 56);
      expect(evidence(journal, 'audioOutputSnapshot'), {
        'supported': 1,
        'success': 1,
        'appAudioSessionState': 0,
      });
    },
  );

  test('call sampling is throttled while exports share one in-flight read', () {
    fakeAsync((clock) {
      final pending = Completer<Map<Object?, Object?>?>();
      var reads = 0;
      final sampler = DiagnosticAudioOutputSampler(
        journal: DiagnosticJournal(enabled: true),
        windows: true,
        elapsed: () => clock.elapsed,
        readState: () {
          reads++;
          return pending.future;
        },
      );
      sampler.sample(duringCall: true);
      sampler.sample();
      sampler.sample(duringCall: true);
      clock.flushMicrotasks();
      expect(reads, 1);
      pending.complete(active);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 9));
      sampler.sample(duringCall: true);
      clock.flushMicrotasks();
      expect(reads, 1);
      clock.elapse(const Duration(seconds: 1));
      sampler.sample(duringCall: true);
      clock.flushMicrotasks();
      expect(reads, 2);
    });
  });

  test(
    'timeout returns failure without launching another unfinished reader',
    () {
      fakeAsync((clock) {
        final pending = Completer<Map<Object?, Object?>?>();
        final journal = DiagnosticJournal(enabled: true);
        var reads = 0;
        final sampler = DiagnosticAudioOutputSampler(
          journal: journal,
          windows: true,
          readState: () {
            reads++;
            return pending.future;
          },
        );
        sampler.sample();
        clock.elapse(const Duration(seconds: 3));
        expect(evidence(journal, 'audioOutputSnapshot')['success'], 0);
        sampler.sample();
        clock.flushMicrotasks();
        expect(reads, 1);
        pending.complete(active);
        clock.flushMicrotasks();
        expect(evidence(journal, 'audioOutputSnapshot')['success'], 1);
        sampler.sample();
        clock.flushMicrotasks();
        expect(reads, 2);
      });
    },
  );

  test(
    'foreign fields, invalid types and private values never enter reports',
    () {
      final journal = DiagnosticJournal(enabled: true);
      journal.recordAudioOutputState({
        ...active,
        'pid': 123456789,
        'deviceId': 'PRIVATE_CANARY',
        'path': _Private(),
        'providerError': _Private(),
        'appVolumePercent': -1,
        'outputVolumePercent': 101,
        'outputMuted': 'false',
        'appMuted': 0,
      });
      expect(evidence(journal, 'audioOutputSnapshot'), {
        'supported': 1,
        'success': 0,
        'appAudioSessionState': 1,
        'outputIsDefault': 1,
        'outputIsCommunicationsDefault': 1,
        'outputDefaultsSame': 1,
      });
      final text = journal.toJson().toString();
      expect(text, isNot(contains('PRIVATE_CANARY')));
      expect(text, isNot(contains('123456789')));
    },
  );

  test(
    'unknown schemas and ambiguous sessions cannot publish mixer values',
    () {
      final journal = DiagnosticJournal(enabled: true);
      journal.recordAudioOutputState({...active, 'schema': 'other'});
      expect(evidence(journal, 'audioOutputSnapshot'), {
        'supported': 0,
        'success': 0,
      });
      journal.recordAudioOutputState({...active, 'sessionState': 2});
      expect(evidence(journal, 'audioOutputSnapshot'), {
        'supported': 1,
        'success': 1,
        'appAudioSessionState': 2,
        'outputDefaultsSame': 1,
      });
      journal.recordAudioOutputState(null);
      expect(evidence(journal, 'audioOutputSnapshot'), {
        'supported': 0,
        'success': 0,
      });
    },
  );
}
