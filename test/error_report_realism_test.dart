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

  test('real failures survive redaction with their cause intact', () {
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
      final message = entry['message']! as String;
      expect(
        message.trim(),
        isNotEmpty,
        reason: 'an entry that says nothing is a lie about having diagnostics',
      );
      expect(
        message,
        isNot('<id>'),
        reason: 'redaction must not swallow the whole message',
      );
      expect(
        entry['frames'],
        isNotNull,
        reason: 'without a frame nobody knows where to look',
      );
    }

    // Each cause is still nameable after redaction — this is the whole point.
    final messages = [
      for (final e in entries.cast<Map<String, Object?>>())
        e['message']! as String,
    ];
    expect(messages[0], contains('hex'), reason: 'a malformed id says so');
    expect(messages[1], contains('No such file'));
    expect(messages[2], contains('FormatException'));
    expect(messages[3], contains('Null check'));
  });

  test('a path in a real exception is redacted but the failure survives', () {
    // The most common shape in this app: an OS error quoting a store path.
    capture(
      'zone',
      () => File(
        '${Platform.environment['HOME']}/Library/Application Support/x.store',
      ).readAsBytesSync(),
    );
    final message = errorJournal.entries.single.message;

    expect(message, contains('<path>'), reason: 'the home directory is gone');
    expect(message, isNot(contains('/Users/')));
    expect(
      message,
      contains('No such file'),
      reason: 'and yet the reader still learns what failed',
    );
  });
}
