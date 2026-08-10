// The other direction of the reachability gate.
//
// `arb_keys_reachable_test` watches for a KEY with no call site. It cannot see
// the opposite mistake — a call site with no key — and that one is worse: an
// unreachable key costs each language a wasted entry, while an unkeyed string
// is shipped English to everyone, in every language, forever.
//
// Both were live here. The chat list said "wants to connect", "request sent"
// and "blocked" in English whatever the app's language was, and the
// foreground-service notification a call raises — the one that appears in the
// shade of a phone that is ringing — said "Incoming xVeil call" the same way.
//
// WHAT THIS CATCHES, and it is deliberately less than everything. A literal of
// two or more words in `lib/features`, which is the shape a sentence has. A
// single-word label ("blocked") slips through, and widening the rule to catch
// it turns the check into 317 hits of font families, enum tags and widget
// keys — a list nobody reads is not a gate. Two words is where the signal is.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Lines that are about the program talking to ITSELF: a thrown message, a
  /// platform-channel name, a parse. None of it reaches a person.
  final internal = RegExp(
    r'throw |Error\(|Exception\(|assert\(|devLog|ValueKey|MethodChannel'
    r'|invokeMethod|Uri\.|\.parse\(|RegExp\(|debugPrint',
  );

  /// Identifiers, paths, URLs and asset names wearing quotes.
  final notProse = RegExp(
    r"^[a-z0-9_./:\-]+$|^[A-Z_]+$|package:|assets/|^http|/v1/|\.dart$|\.json$|^\d",
  );

  final singleQuoted = RegExp(r"'((?:[^'\\\n$]|\\.){6,90})'");
  final twoWords = RegExp(r'[a-z]{2,}\s+[a-z]{2,}');

  test('no user-facing sentence in lib/features is written without a key', () {
    final offenders = <String>[];
    for (final entity in Directory('lib/features').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Emoji search keywords: hundreds of two-word English phrases that are
      // matched against typing, never displayed.
      if (entity.path.endsWith('emoji_data.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
        if (internal.hasMatch(line)) continue;
        for (final m in singleQuoted.allMatches(line)) {
          final text = m.group(1)!;
          if (notProse.hasMatch(text)) continue;
          if (!twoWords.hasMatch(text)) continue;
          final where = '${entity.path}:${i + 1}';
          if (_knownInternal.contains(where)) continue;
          offenders.add('$where: ${text.trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these read like something a person is meant to read, and they are '
          'not in the ARB — so they ship in English to every language:\n'
          '  ${offenders.join("\n  ")}\n'
          'Add a key and use it. If the string is really internal (a thrown '
          'message, a channel name), the line probably wants the shape the '
          'other internal strings have rather than an entry below.',
    );
  });

  test('the known-internal list does not rot', () {
    for (final where in _knownInternal) {
      final parts = where.split(':');
      final file = File(parts.first);
      expect(
        file.existsSync(),
        isTrue,
        reason: '$where names a file that no longer exists — prune the list',
      );
      final lineNo = int.parse(parts.last);
      final lines = file.readAsLinesSync();
      expect(
        lineNo <= lines.length,
        isTrue,
        reason: '$where is past the end of the file — prune the list',
      );
    }
  });
}

/// Sites that look like prose and are not: both are messages the program
/// hands to itself on a path that cannot happen, kept as text because that is
/// what a reader of the stack trace needs.
///
/// Line numbers, deliberately: an entry that drifts is an entry nobody
/// re-checked, and the second test above fails when one points past the end of
/// its file. The list may shrink and must not grow — a new sentence in the UI
/// layer belongs in the ARB.
const _knownInternal = <String>{
  'lib/features/chat/video_player_screen.dart:42',
  'lib/features/network/node_config_screen.dart:105',
};
