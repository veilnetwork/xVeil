import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';

/// Does a report actually say what went wrong?
///
/// The mechanics are covered elsewhere (redaction, the allow-list, the ring).
/// This asks the question the feature exists for: hand this blob to whoever
/// wrote the code — can they act on it? A report that survives redaction but
/// says nothing useful is worse than none, because it looks like diagnostics.
///
/// Since audit X-06 the exported record carries no exception TEXT, so the
/// question is sharper: with only the exception class and a stack location, is
/// a real failure still recognisable? These are the four shapes this app
/// actually throws.
void main() {
  setUp(errorJournal.clear);

  /// Capture a genuinely thrown error, the way the zone handler would.
  void capture(String kind, void Function() body) {
    try {
      body();
    } catch (error, stack) {
      errorJournal.record(kind: kind, error: error, stack: stack, atMs: 1);
    }
  }

  test('real failures are still nameable from what is exported', () {
    capture('platform', () => NodeId.fromHex('not-a-node-id'));
    capture('zone', () => File('/no/such/path/xveil.store').readAsBytesSync());
    capture('zone', () => jsonDecode('{"truncated":'));
    capture('flutter', () => (<String, int>{}['missing']! + 1));

    final report = errorJournal.toJson(
      platform: 'macos',
      osVersion: '26.0',
      appVersion: '1.0.0+1',
      defaultProfile: true,
      phase: 'ready',
    );
    final entries = (jsonDecode(report) as Map)['errors']! as List;
    expect(entries, hasLength(4));

    for (final entry in entries.cast<Map<String, Object?>>()) {
      expect(
        (entry['type']! as String).trim(),
        isNotEmpty,
        reason: 'an entry that says nothing is a lie about having diagnostics',
      );
      expect(
        entry.containsKey('message'),
        isFalse,
        reason: 'free text does not leave the device (audit X-06)',
      );
      expect(
        entry['frames'],
        isNotNull,
        reason: 'without a frame nobody knows where to look',
      );
    }

    // Each cause is distinguishable from its class alone — the whole point of
    // dropping the text without dropping the diagnostic.
    final types = [
      for (final e in entries.cast<Map<String, Object?>>()) e['type']! as String,
    ];
    expect(types[0], 'ArgumentError', reason: 'a malformed id');
    expect(types[1], 'PathNotFoundException', reason: 'a missing store');
    expect(types[2], 'FormatException', reason: 'truncated JSON');
    expect(types[3], contains('TypeError'), reason: 'a null check');
    expect(
      types.toSet(),
      hasLength(4),
      reason: 'four different bugs must not export as one indistinguishable row',
    );

    // The sentence is not lost — it is just kept where the person is.
    final messages = errorJournal.entries.map((e) => e.message).toList();
    expect(messages[0], contains('hex'));
    expect(messages[1], contains('No such file'));
    expect(messages[2], contains('FormatException'));
    expect(messages[3], contains('Null check'));
  });

  test('a path in a real exception never reaches the report', () {
    // The most common shape in this app: an OS error quoting a store path.
    capture(
      'zone',
      () => File(
        '${Platform.environment['HOME']}/Library/Application Support/x.store',
      ).readAsBytesSync(),
    );
    final message = errorJournal.entries.single.message;

    // In memory the path is redacted — this string can reach a screen.
    expect(message, contains('<path>'), reason: 'the home directory is gone');
    expect(message, isNot(contains('/Users/')));
    expect(
      message,
      contains('No such file'),
      reason: 'and yet the reader still learns what failed',
    );

    // In the export the quoted path is not redacted, it is absent: the whole
    // sentence stays home and the class name carries the diagnostic.
    final report = errorJournal.toJson(
      platform: 'macos',
      osVersion: '26.0',
      appVersion: '1.0.0+1',
      defaultProfile: true,
      phase: 'ready',
    );
    expect(report, isNot(contains('Application Support')));
    expect(report, isNot(contains('<path>')));
    expect(report, contains('PathNotFoundException'));
  });
}
