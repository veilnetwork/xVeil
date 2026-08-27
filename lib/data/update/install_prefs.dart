import 'dart:convert';
import 'dart:io';

/// The two facts about update checks that belong to the INSTALL, not to a
/// profile.
///
/// Everything else this app remembers is per profile, and rightly so: profiles
/// are meant to be independent. These two are different, because what they
/// govern is a packet leaving the machine.
///
/// `SharedPreferences` looked install-wide and is not: production swaps the
/// platform backend for a file inside the active profile's directory. So a
/// person who turned update checks off in one profile got a request to
/// github.com from the next one, and the daily throttle restarted per profile
/// — one beacon per profile per day, each one timed to that profile being
/// opened (report15 X15-M17). I had earlier reported that this did not hold,
/// on the strength of the provider not being overridden anywhere; the backend
/// swap is what I had not looked at.
///
/// Shared across profiles ON PURPOSE, and it makes them less distinguishable
/// rather than more: the stamp says a check happened, never which profile made
/// it, so a check from a hidden profile is indistinguishable from one made by
/// the profile anybody can see. The alternative — a stamp per profile — is
/// what let each of them announce itself.
///
/// Two keys, no history, nothing that names a profile.
class InstallUpdatePrefs {
  InstallUpdatePrefs(this.path);

  /// Beside the profile directories, never inside one.
  static String pathIn(String supportDir) => '$supportDir/xveil.install.json';

  final String path;

  /// True when the file is THERE and could not be understood.
  ///
  /// Kept apart from "not there", because the two mean opposite things for the
  /// one setting that stops a packet. A missing file is a fresh install and
  /// the defaults apply; a corrupt one may be somebody's opt-out that this
  /// process cannot read, and reading it as "no opt-out" is how a choice is
  /// lost by accident (report16 XV-14).
  bool _unreadable = false;

  Map<String, Object?> _read() {
    final file = File(path);
    try {
      if (!file.existsSync()) {
        _unreadable = false;
        return {};
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, Object?>) {
        _unreadable = false;
        return decoded;
      }
    } catch (_) {
      // Fall through: there is a file and it did not parse.
    }
    _unreadable = true;
    return {};
  }

  /// Did the write reach the disk?
  ///
  /// Answered rather than swallowed. A read-only directory or a full disk
  /// leaves this file exactly as it was, and the two things it holds both stop
  /// meaning what the caller thinks: an opt-out that is not on disk is back to
  /// "on" at the next launch, and a check stamp that is not on disk makes
  /// every launch ask github.com again (report17 XV17-M2).
  bool _write(Map<String, Object?> values) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      // Written beside and renamed over. `writeAsStringSync` truncates first,
      // so a crash or a full disk in the middle leaves a half-written file —
      // which the reader cannot parse, and which is exactly the state that
      // must not be read as "nobody opted out".
      final temp = File('$path.tmp');
      temp.writeAsStringSync(jsonEncode(values), flush: true);
      temp.renameSync(path);
      _unreadable = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The stamp this SESSION has set, whether or not it reached the disk.
  ///
  /// A stamp that could not be written used to be forgotten entirely, so a
  /// device with a read-only support directory asked github.com on every
  /// launch — and, within one long-running session, on every check. Held here
  /// so the interval still holds for as long as this process lives; the disk
  /// is what makes it hold across launches, and that part cannot be faked.
  DateTime? _sessionLastCheck;

  /// Whether to look for a newer release at all. Null when nobody has said.
  bool? get enabled {
    final values = _read();
    // A file that is there and unreadable answers NO, not "nobody said".
    // Whatever it held, the direction that sends no packet is the one to take
    // when the answer cannot be read.
    if (_unreadable) return false;
    final value = values['enabled'];
    return value is bool ? value : null;
  }

  set enabled(bool? value) {
    setEnabled(value);
  }

  /// [enabled], reporting whether the choice reached the disk.
  ///
  /// The setter above stays for callers that cannot act on the answer; this is
  /// for the one that can. A choice that did not persist is honoured for this
  /// session and gone at the next launch, and the person is entitled to know
  /// which of the two they got.
  bool setEnabled(bool? value) {
    final values = _read();
    if (value == null) {
      values.remove('enabled');
    } else {
      values['enabled'] = value;
    }
    return _write(values);
  }

  /// When the last check happened, so the next is a day later and not a launch
  /// later. Null when none has.
  DateTime? get lastCheck {
    final value = _read()['lastCheckMs'];
    final stored = value is int
        ? DateTime.fromMillisecondsSinceEpoch(value)
        : null;
    final session = _sessionLastCheck;
    if (stored == null) return session;
    if (session == null) return stored;
    // The later of the two: a stamp this session set but could not write is
    // still the last time this device asked.
    return session.isAfter(stored) ? session : stored;
  }

  set lastCheck(DateTime? value) {
    _sessionLastCheck = value;
    final values = _read();
    if (value == null) {
      values.remove('lastCheckMs');
    } else {
      values['lastCheckMs'] = value.millisecondsSinceEpoch;
    }
    _write(values);
  }
}
