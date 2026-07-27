import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';

void main() {
  group('what a report must never carry', () {
    // This is a deniable messenger: a diagnostics blob is a disclosure risk
    // before it is a debugging aid. Whoever receives it must not learn who the
    // sender is, whom they talk to, or what they said.
    test('a node or content id is replaced, not shortened', () {
      const id =
          '7084a345b55ef17031b793b96a9edca2cb1836151490c3a67d1ceab906f2a8a2';
      final out = ErrorJournal.redact('no route to peer $id');
      expect(out, isNot(contains(id)));
      expect(out, isNot(contains(id.substring(0, 16))));
      expect(out, contains('<id>'));
    });

    test('a home directory is replaced — it names the person', () {
      for (final path in [
        '/Users/alice/Library/Application Support/network.veil.xveil/x.store',
        '/home/vi/xVeil/build/app',
        r'C:\Users\alice\AppData\Local\xveil',
      ]) {
        final out = ErrorJournal.redact('cannot open $path');
        expect(out, isNot(contains('alice')));
        expect(out, isNot(contains('/home/vi')));
        expect(out, contains('<path>'));
      }
    });

    test('a long base64 run is replaced — it is a payload or a key', () {
      // Deliberately NOT all-hex: a hex run is caught by the id rule first,
      // which is also correct but tests a different sentence.
      final blob = 'zK9+/${'Qx7' * 20}';
      final out = ErrorJournal.redact('bad frame $blob');
      expect(out, isNot(contains(blob)));
      expect(out, contains('<blob>'));
    });

    test('an enormous message is capped', () {
      // Ordinary prose, so the cap is what shortens it rather than a
      // redaction rule swallowing the whole string.
      final out = ErrorJournal.redact(List.filled(2000, 'why').join(' '));
      expect(out.length, lessThan(400));
      expect(out, endsWith('…'));
    });

    test('a stack contributes only package locations, never file paths', () {
      final journal = ErrorJournal();
      journal.record(
        kind: 'zone',
        error: StateError('boom'),
        stack: StackTrace.fromString(
          '#0      Foo.bar (package:xveil/state/a.dart:12:3)\n'
          '#1      main (/Users/alice/Projects/xVeil/lib/main.dart:44:5)\n'
          '#2      _run (dart:async/zone.dart:100:9)',
        ),
        atMs: 1,
      );
      final frames = journal.entries.single.frames;
      expect(frames, contains('package:xveil/state/a.dart:12:3'));
      expect(frames.any((f) => f.contains('/Users/')), isFalse);
      expect(frames.any((f) => f.startsWith('dart:')), isTrue);
    });
  });

  group('the report itself', () {
    test('is valid JSON with the fields a reader needs and nothing else', () {
      final journal = ErrorJournal()
        ..record(kind: 'flutter', error: 'widget blew up', atMs: 7);
      final decoded =
          jsonDecode(
                journal.toJson(
                  platform: 'macos',
                  osVersion: '26.0',
                  appVersion: '1.0.0+1',
                  profile: 'default',
                  phase: 'ready',
                ),
              )
              as Map<String, Object?>;

      expect(decoded['schema'], 'xveil-error-report/1');
      expect(decoded.keys, {
        'schema',
        'app',
        'platform',
        'os',
        'profile',
        'phase',
        'errors',
      }, reason: 'an allow-list: a new field must be a deliberate decision');
      final errors = decoded['errors']! as List;
      expect(errors, hasLength(1));
      expect((errors.single as Map)['kind'], 'flutter');
      expect((errors.single as Map)['message'], 'widget blew up');
    });

    test('keeps the NEWEST failures when it overflows', () {
      // The failure a tester is reporting is the one that just happened.
      final journal = ErrorJournal(capacity: 3);
      for (var i = 0; i < 10; i++) {
        journal.record(kind: 'zone', error: 'error $i', atMs: i);
      }
      expect(journal.entries, hasLength(3));
      expect(
        journal.entries.map((e) => e.message),
        ['error 7', 'error 8', 'error 9'],
      );
    });

    test('an empty journal still produces a usable report', () {
      final decoded =
          jsonDecode(
                ErrorJournal().toJson(
                  platform: 'linux',
                  osVersion: '?',
                  appVersion: '1.0.0+1',
                  profile: 'debug',
                  phase: 'locked',
                ),
              )
              as Map<String, Object?>;
      expect(decoded['errors'], isEmpty);
      expect(
        decoded['phase'],
        'locked',
        reason: '"nothing crashed but it is stuck" is itself a report',
      );
    });
  });
}
