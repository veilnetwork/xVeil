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
      expect(frames, contains('dart:async/zone.dart:100:9'));
      // The absolute path must be DROPPED, not shortened. Its tail reads
      // `dart:44:5`, which looks like an SDK frame and points at nothing —
      // asserting only "no /Users/" is satisfied by exactly that lie.
      expect(
        frames,
        isNot(contains('dart:44:5')),
        reason: 'a file path must not survive as a fake SDK frame',
      );
      expect(frames, hasLength(2), reason: 'two real frames, the path dropped');
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
      expect(
        decoded.keys,
        {'schema', 'app', 'platform', 'os', 'profile', 'phase', 'errors'},
        reason: 'an allow-list: a new field must be a deliberate decision',
      );
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
      expect(journal.entries.map((e) => e.message), [
        'error 7',
        'error 8',
        'error 9',
      ]);
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

  group('a failure that repeats', () {
    // Repeats are the normal case, not the exception: a screen that fails to
    // load fails again every time it is opened. Before this, sixty repeats of
    // one transient error filled the ring and evicted an unlock failure — the
    // report described nothing but the noise.

    test('collapses into one entry that counts', () {
      final journal = ErrorJournal();
      for (var i = 0; i < 5; i++) {
        journal.record(kind: 'screen:chats', error: 'list failed', atMs: i);
      }
      expect(journal.entries, hasLength(1));
      expect(journal.entries.single.count, 5);
    });

    test('does NOT evict a different failure', () {
      // The point of the whole change.
      final journal = ErrorJournal(capacity: 3);
      journal.record(kind: 'unlock', error: 'the one that matters', atMs: 0);
      for (var i = 0; i < 60; i++) {
        journal.record(kind: 'screen:chats', error: 'transient', atMs: i);
      }
      expect(
        journal.entries.map((e) => e.message),
        contains('the one that matters'),
      );
    });

    test('brackets the burst — first seen and last seen', () {
      // A hundred failures in a second and a hundred over a day are different
      // bugs wearing the same message.
      final journal = ErrorJournal();
      journal.record(kind: 'zone', error: 'flap', atMs: 1000);
      journal.record(kind: 'zone', error: 'flap', atMs: 4000);
      final entry = journal.entries.single;
      expect(entry.firstAtMs, 1000);
      expect(entry.atMs, 4000);
    });

    test(
      'a repeat moves to the end, so a recurring failure is not aged out',
      () {
        final journal = ErrorJournal(capacity: 2);
        journal.record(kind: 'zone', error: 'recurring', atMs: 0);
        journal.record(kind: 'zone', error: 'other', atMs: 1);
        journal.record(kind: 'zone', error: 'recurring', atMs: 2);
        journal.record(kind: 'zone', error: 'newest', atMs: 3);
        expect(
          journal.entries.map((e) => e.message),
          ['recurring', 'newest'],
          reason: 'the one still happening outranks the one that stopped',
        );
      },
    );

    test('a different KIND with the same text stays separate', () {
      // "no route" from the node and from a screen are different problems.
      final journal = ErrorJournal();
      journal.record(kind: 'node', error: 'no route', atMs: 0);
      journal.record(kind: 'screen:chats', error: 'no route', atMs: 1);
      expect(journal.entries, hasLength(2));
    });

    test('the count only appears when there IS one', () {
      final journal = ErrorJournal()
        ..record(kind: 'zone', error: 'once', atMs: 1);
      final once =
          jsonDecode(
                journal.toJson(
                  platform: 'linux',
                  osVersion: '1',
                  appVersion: '1',
                  profile: 'default',
                  phase: 'ready',
                ),
              )
              as Map<String, Object?>;
      expect(
        ((once['errors']! as List).single as Map).keys,
        {'kind', 'at', 'message'},
        reason: 'an allow-list for entries too — a single failure stays lean',
      );

      journal.record(kind: 'zone', error: 'once', atMs: 2);
      final twice =
          jsonDecode(
                journal.toJson(
                  platform: 'linux',
                  osVersion: '1',
                  appVersion: '1',
                  profile: 'default',
                  phase: 'ready',
                ),
              )
              as Map<String, Object?>;
      expect(((twice['errors']! as List).single as Map).keys, {
        'kind',
        'at',
        'count',
        'firstAt',
        'message',
      });
    });
  });
}
