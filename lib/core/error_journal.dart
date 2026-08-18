import 'dart:convert';

/// A bounded record of what went wrong, shaped to be pasted somewhere.
///
/// The point is a report a tester can hand over that says what broke — and
/// says nothing else. This is a deniable messenger, so a diagnostics blob is a
/// disclosure risk before it is a debugging aid: whoever receives it must not
/// learn who the sender is, whom they talk to, or what they said.
///
/// The EXPORT is therefore an allow-list in the literal sense: every value that
/// [toJson] emits is one this app chose — a `kind` label written at the call
/// site, the exception's class name, `package:`/`dart:` stack locations,
/// timestamps and counts. Nothing that an error filled in for itself goes out.
///
/// The exception's own TEXT does not, and that is the point of the split. Four
/// of the record sites are catch-alls — `FlutterError.onError`,
/// `PlatformDispatcher.onError`, the root zone, and the async-error screen —
/// and they are handed an arbitrary `Object`. There is no typed code to
/// substitute at a site that does not know what it caught, so the message can
/// only ever be free text run through a deny-list, and a deny-list only removes
/// what someone thought of (audit X-06). It stays in memory, where it tells one
/// failure from another and can be shown to the person on their own device; it
/// does not ride out on the clipboard.
class ErrorJournal {
  ErrorJournal({this.capacity = 50});

  /// Old entries are dropped, not the new ones: the failure a tester is
  /// reporting is the one that just happened.
  final int capacity;

  final List<RecordedError> _entries = [];

  List<RecordedError> get entries => List.unmodifiable(_entries);

  /// The kinds that mean a lock or wipe did NOT finish what it claimed: a
  /// node whose stop ran out of its budget, a teardown step abandoned so the
  /// container lock could still be released, or a VPN backend that never
  /// confirmed the tunnel was down.
  ///
  /// Named here rather than at the screen because the recording sites are
  /// what define them, and a reader looking at either end should find the
  /// same list.
  static const incompleteTeardownKinds = {
    'teardown-abandoned',
    'node-stop-abandoned',
    'vpn-stop-incomplete',
  };

  /// Whether the last teardown left something running.
  ///
  /// The screen says "locked" the moment the keys are gone — which is the
  /// right order, since holding them through a stuck teardown is the worse
  /// outcome — but a node that outlived its stop still holds its sockets and
  /// its network identity, and a tunnel that never confirmed may still be
  /// routing. Both were journaled and neither was ever said out loud.
  bool get teardownLeftSomethingRunning =>
      _entries.any((e) => incompleteTeardownKinds.contains(e.kind));

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
    // Redacted even though it never leaves via [toJson]: it is held in RAM and
    // may be shown on screen, and a node id on a screenshot is still a node id.
    final message = redact(error.toString());
    // The runtime type is the part of an exception that is reliably about the
    // FAILURE rather than about the data it happened to touch. It is the one
    // thing an arbitrary caught `Object` yields that this app can vouch for,
    // which is what lets the exported record drop the message entirely.
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
  /// no node id anywhere in here — and, since audit X-06, no exception text
  /// either: see [RecordedError.toJson].
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
  /// Conservative on purpose: it is better for a message to read `<id>` where a
  /// hash was than to keep a node id legible on a screenshot. The length cap
  /// exists because an exception message can quote a whole payload.
  ///
  /// Honest about what this is: a DENY-list over free text, and a deny-list
  /// only removes what someone thought of. That is exactly why the string it
  /// produces is an IN-MEMORY convenience and not part of the report. This is
  /// a second line behind [RecordedError.toJson] dropping the message, not the
  /// thing standing between an exception and someone else's clipboard.
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
  /// Always a literal written in this app's source, never anything the error
  /// supplied — which is what makes it exportable.
  final String kind;

  /// The exception's runtime type: a class name, which describes the FAILURE
  /// and not the data that tripped it. This is the diagnostic the report is
  /// built on now that [message] stays home.
  final String type;

  /// The redacted exception text. Held for the screen a person can read on
  /// their OWN device, and to tell two failures apart when repeats collapse —
  /// never emitted by [toJson].
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

  /// What actually leaves the device.
  ///
  /// [message] is absent on purpose. Every key below holds a value this app
  /// wrote — a call-site label, a class name, `package:`/`dart:` locations, a
  /// clock reading, a count — so the record is an allow-list by construction
  /// rather than by whatever a deny-list happened to catch. The exception's own
  /// text is the one thing here that an arbitrary thrower fills in, and a
  /// catch-all handler cannot know what it is holding (audit X-06).
  ///
  /// What a reader loses is the sentence; what they keep is which net caught
  /// it, which exception class it was, where in the code, how often, and over
  /// what span. That is enough to find `PathNotFoundException` in the unlock
  /// path — and it cannot carry a contact, a payload or a path.
  Map<String, Object?> toJson() => {
    'kind': kind,
    'type': type,
    'at': atMs,
    if (count > 1) 'count': count,
    if (count > 1) 'firstAt': firstAtMs,
    if (frames.isNotEmpty) 'frames': frames,
  };
}

/// The app-wide journal. A plain global for the same reason the error handlers
/// are: it has to be reachable from the zone handler, which runs outside any
/// provider scope.
final errorJournal = ErrorJournal();
