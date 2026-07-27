import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A caught exception must never reach user-visible text raw.
///
/// Exceptions in this app quote node ids, store paths, key paths and bind
/// addresses. A screen, snackbar or toast showing one puts that in front of
/// whoever is standing nearby, and into any screenshot the person sends while
/// asking for help — in a messenger whose premise is that its contents are
/// deniable.
///
/// The per-site tests are not enough on their own: they cover the sites that
/// exist, and this mistake comes back with the next screen someone writes.
/// Hence a check against the source itself. It found four sites a careful
/// manual sweep had already missed, so it earns its keep.
///
/// The way through is `shownCause()` (or `AsyncErrorView` for a failed load):
/// the cause still shows, the identifying parts are redacted, and the full
/// text reaches the error report.
void main() {
  /// Only a BARE interpolation counts. `$e` on its own is an exception by
  /// convention; `${e.peerHex}`, `${e.key}`, `${e.char}` are loop variables
  /// and entities, and flagging those would make the check noise that people
  /// learn to ignore.
  final bare = RegExp(
    r'\$(e|err|error|ex|exception)\b(?![\w.])'
    r'|\$\{(e|err|error|ex|exception)\}'
    r'|\b(e|err|error|ex|exception)\.toString\(\)',
    caseSensitive: false,
  );

  /// Logging the raw thing is correct — the developer log is not user-visible
  /// and stripping it there would cost the diagnosis. Log calls span several
  /// lines, so the check looks back as well as at the line itself.
  final logging = RegExp(
    r'\b(devLog|debugPrint|print|stderr|stdout|assert)\b|xVeil\[',
  );

  test('no caught exception reaches user-visible text in lib/features', () {
    final offenders = <String>[];
    for (final entity in Directory('lib/features').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The helper that does the redacting names the pattern it replaces.
      if (entity.path.endsWith('shown_cause.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (!bare.hasMatch(line)) continue;
        final windowStart = i - 6 < 0 ? 0 : i - 6;
        final window = lines.sublist(windowStart, i + 1).join('\n');
        if (logging.hasMatch(window)) continue;
        offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these put a raw exception in front of the user — route them through '
          'shownCause() so the cause survives and the identifiers do not:\n'
          '${offenders.join('\n')}',
    );
  });
}
