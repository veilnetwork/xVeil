import 'dart:convert';

/// A bounded record of what went wrong, shaped to be pasted somewhere.
///
/// The point is a report a tester can hand over that says what broke — and
/// says nothing else. This is a deniable messenger, so a diagnostics blob is a
/// disclosure risk before it is a debugging aid: whoever receives it must not
/// learn who the sender is, whom they talk to, or what they said. Everything
/// below is therefore an allow-list. Nothing is copied in because it "might be
/// useful"; a field earns its place by naming a failure, not a person.
class ErrorJournal {
  ErrorJournal({this.capacity = 50});

  /// Old entries are dropped, not the new ones: the failure a tester is
  /// reporting is the one that just happened.
  final int capacity;

  final List<RecordedError> _entries = [];

  List<RecordedError> get entries => List.unmodifiable(_entries);

  void record({
    required String kind,
    required Object error,
    StackTrace? stack,
    required int atMs,
  }) {
    _entries.add(
      RecordedError(
        kind: kind,
        message: redact(error.toString()),
        frames: _topFrames(stack),
        atMs: atMs,
      ),
    );
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  void clear() => _entries.clear();

  /// The report, as JSON.
  ///
  /// [phase] and [profile] are included because they change what "broken"
  /// means; neither identifies anyone. There is deliberately no identity, no
  /// contact, no message body, no store path and no node id anywhere in here.
  String toJson({
    required String platform,
    required String osVersion,
    required String appVersion,
    required String profile,
    required String phase,
  }) => const JsonEncoder.withIndent('  ').convert({
    'schema': 'xveil-error-report/1',
    'app': appVersion,
    'platform': platform,
    'os': osVersion,
    'profile': profile,
    'phase': phase,
    'errors': [for (final entry in _entries) entry.toJson()],
  });

  /// The first frames of [stack], as `package:…` locations only.
  ///
  /// Absolute paths are dropped rather than redacted: a stack from a debug
  /// build carries the developer's home directory, and on a tester's machine
  /// it carries theirs.
  static List<String> _topFrames(StackTrace? stack, {int keep = 6}) {
    if (stack == null) return const [];
    final frames = <String>[];
    for (final line in stack.toString().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final match = _frameLocation.firstMatch(trimmed);
      if (match == null) continue;
      frames.add(match.group(0)!);
      if (frames.length >= keep) break;
    }
    return frames;
  }

  /// The scheme must START a URI, not merely appear inside one.
  ///
  /// Without the lookbehind this matches the TAIL of any absolute path ending
  /// in `.dart:LINE:COL` — `/Users/someone/lib/main.dart:44:5` yields the
  /// frame `dart:44:5`, which reads like SDK code and is not. The path is gone
  /// either way, so a test asserting "no home directory" is satisfied by the
  /// wrong thing; the point here is that an unusable frame must be DROPPED,
  /// not shortened into a plausible-looking lie.
  static final _frameLocation = RegExp(
    r'(?<![\w./])(?:package:|dart:)[\w./]+(?::\d+)?(?::\d+)?',
  );

  /// Strip anything that could name a person or their data.
  ///
  /// Conservative on purpose: it is better for a report to read
  /// `<id>` where a hash was than to carry a node id into a group chat. The
  /// caps exist because an exception message can quote a whole payload.
  static String redact(String raw, {int maxLength = 300}) {
    var text = raw
        // Node ids, content ids, epoch keys: 32 bytes as hex.
        .replaceAll(_hex64, '<id>')
        // A home directory names the person on most desktops.
        .replaceAll(_homePath, '<path>')
        // Anything long and base64-ish is a payload, a key or a blob.
        .replaceAll(_base64Blob, '<blob>');
    if (text.length > maxLength) {
      text = '${text.substring(0, maxLength)}…';
    }
    return text;
  }

  static final _hex64 = RegExp(r'\b[0-9a-fA-F]{32,}\b');
  static final _homePath = RegExp(r'(/Users/|/home/|C:\\Users\\)[^\s"\)]+');
  static final _base64Blob = RegExp(r'\b[A-Za-z0-9+/]{40,}={0,2}\b');
}

class RecordedError {
  const RecordedError({
    required this.kind,
    required this.message,
    required this.frames,
    required this.atMs,
  });

  /// Which net caught it: `flutter`, `platform`, `zone`, or a caller's label.
  final String kind;
  final String message;
  final List<String> frames;
  final int atMs;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'at': atMs,
    'message': message,
    if (frames.isNotEmpty) 'frames': frames,
  };
}

/// The app-wide journal. A plain global for the same reason the error handlers
/// are: it has to be reachable from the zone handler, which runs outside any
/// provider scope.
final errorJournal = ErrorJournal();
