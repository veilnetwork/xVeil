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

  /// Record a failure, collapsing a repeat of one already held.
  ///
  /// Repeats are the normal case, not the exception: a screen that fails to
  /// load fails again every time it is opened, and a flapping one can fail
  /// dozens of times a minute. Appending each would fill the ring with copies
  /// of the loudest failure and push out the one the person is actually
  /// reporting — measured, and it does: sixty repeats of a transient list
  /// error evicted an unlock failure entirely.
  ///
  /// So a repeat bumps a count and moves the entry to the end, which makes the
  /// ring hold the newest DISTINCT failures. "This happened 60 times between
  /// these two moments" is also a better sentence than sixty identical rows —
  /// it says whether something is a burst or a slow drip.
  void record({
    required String kind,
    required Object error,
    StackTrace? stack,
    required int atMs,
  }) {
    final message = redact(error.toString());
    // The runtime type is the part of an exception that is reliably about the
    // FAILURE rather than about the data it happened to touch, and it survives
    // redaction intact — so the report keeps its diagnostic value while the
    // message can be stripped hard.
    final type = error.runtimeType.toString();
    final existing = _entries.indexWhere(
      (entry) => entry.kind == kind && entry.message == message,
    );
    if (existing >= 0) {
      _entries.add(_entries.removeAt(existing).seenAgain(atMs));
      return;
    }
    _entries.add(
      RecordedError(
        kind: kind,
        type: type,
        message: message,
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
  /// [phase] changes what "broken" means and identifies nobody. There is
  /// deliberately no identity, no contact, no message body, no store path and
  /// no node id anywhere in here.
  ///
  /// The profile is reported as default-or-not rather than by NAME. Whether a
  /// non-default profile was active explains a class of failure; which one it
  /// was is a label the person chose, and in a deniable messenger the mere
  /// existence of a second profile is the fact worth hiding. A pasted report
  /// used to carry it verbatim.
  String toJson({
    required String platform,
    required String osVersion,
    required String appVersion,
    required bool defaultProfile,
    required String phase,
  }) => const JsonEncoder.withIndent('  ').convert({
    'schema': 'xveil-error-report/1',
    'app': appVersion,
    'platform': platform,
    'os': osVersion,
    'profile': defaultProfile ? 'default' : 'custom',
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

  /// Strip everything that could name a person, a peer or a place.
  ///
  /// Conservative on purpose: it is better for a report to read `<id>` where a
  /// hash was than to carry a node id into a group chat. The length cap exists
  /// because an exception message can quote a whole payload.
  ///
  /// Honest about what this is: a DENY-list over free text, and a deny-list
  /// only removes what someone thought of. The class's contract says
  /// allow-list, and the message body is the one field that never satisfied
  /// it — an exception carries whatever the thrower put in it. A real
  /// allow-list means every `record` call site naming a typed code instead of
  /// handing over `error.toString()`, which is a change at ~every throw site
  /// rather than here. Until then this covers the classes an audit named, and
  /// [RecordedError.type] carries the diagnostic that used to justify keeping
  /// the message generous.
  static String redact(String raw, {int maxLength = 300}) {
    var text = raw
        // A whole URL names a host and often a path and query with it.
        .replaceAll(_url, '<url>')
        .replaceAll(_email, '<email>')
        // Peers, relays, bootstrap seeds — an address is a social graph edge.
        .replaceAll(_ipv4, '<ip>')
        .replaceAll(_ipv6, '<ip>')
        // Node ids, content ids, epoch keys. 16 hex, not 32: an 8-byte handle
        // is just as identifying as a 32-byte one and used to pass straight
        // through.
        .replaceAll(_hexId, '<id>')
        // Any absolute path, not just a home directory: /var and /private name
        // the machine's layout, and an app-support path carries the profile.
        .replaceAll(_absPath, '<path>')
        .replaceAll(_winPath, '<path>')
        // Anything base64-ish. 20 chars, not 40: a 16-byte token is 22
        // characters before its padding, so the old floor let every one of
        // them through — and 16 bytes is the usual size of an API token here.
        //
        // Both alphabets. The pattern used to be standard-base64 only
        // (`+` and `/`), and base64URL — which swaps those for `-` and `_` —
        // went through untouched (audit XV-18). That is the alphabet used
        // wherever a token has to survive a URL or a filename, which is
        // exactly where the tokens in this app live.
        .replaceAll(_base64Blob, '<blob>');
    if (text.length > maxLength) {
      text = '${text.substring(0, maxLength)}…';
    }
    return text;
  }

  static final _hexId = RegExp(r'\b[0-9a-fA-F]{16,}\b');
  static final _absPath = RegExp(r'/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+');
  static final _winPath = RegExp(r'[A-Za-z]:\\[^\s"\)]+');
  static final _base64Blob = RegExp(r'\b[A-Za-z0-9+/_-]{20,}={0,2}');
  static final _ipv4 = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');
  static final _ipv6 = RegExp(r'\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b');
  static final _email = RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\b');
  static final _url = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"\)]+');
}

class RecordedError {
  const RecordedError({
    required this.kind,
    required this.type,
    required this.message,
    required this.frames,
    required this.atMs,
    this.count = 1,
    int? firstAtMs,
  }) : firstAtMs = firstAtMs ?? atMs;

  /// Which net caught it: `flutter`, `platform`, `zone`, or a caller's label.
  final String kind;

  /// The exception's runtime type. Survives redaction because it describes the
  /// FAILURE, not the data that tripped it — which is what lets the message be
  /// stripped hard without leaving the report useless.
  final String type;
  final String message;
  final List<String> frames;

  /// When it last happened.
  final int atMs;

  /// When it first happened. With [atMs] this says whether the failure was a
  /// burst or a slow drip — two very different bugs behind one message.
  final int firstAtMs;

  /// How many times this exact failure was recorded.
  final int count;

  /// The same failure again: keep the first frames (the site is the same) and
  /// the first timestamp, advance the last one.
  RecordedError seenAgain(int atMs) => RecordedError(
    kind: kind,
    type: type,
    message: message,
    frames: frames,
    atMs: atMs,
    firstAtMs: firstAtMs,
    count: count + 1,
  );

  Map<String, Object?> toJson() => {
    'kind': kind,
    'type': type,
    'at': atMs,
    if (count > 1) 'count': count,
    if (count > 1) 'firstAt': firstAtMs,
    'message': message,
    if (frames.isNotEmpty) 'frames': frames,
  };
}

/// The app-wide journal. A plain global for the same reason the error handlers
/// are: it has to be reachable from the zone handler, which runs outside any
/// provider scope.
final errorJournal = ErrorJournal();
