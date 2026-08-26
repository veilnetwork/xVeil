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

  Map<String, Object?> _read() {
    try {
      final file = File(path);
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : {};
    } catch (_) {
      // Unreadable is the same as unset: the defaults are the safe ones — the
      // check is on, and it has never run.
      return {};
    }
  }

  void _write(Map<String, Object?> values) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(values), flush: true);
    } catch (_) {
      // Best effort. A stamp that did not save means the next launch asks
      // again, which is the direction that costs a request rather than the one
      // that ignores somebody's choice.
    }
  }

  /// Whether to look for a newer release at all. Null when nobody has said.
  bool? get enabled {
    final value = _read()['enabled'];
    return value is bool ? value : null;
  }

  set enabled(bool? value) {
    final values = _read();
    if (value == null) {
      values.remove('enabled');
    } else {
      values['enabled'] = value;
    }
    _write(values);
  }

  /// When the last check happened, so the next is a day later and not a launch
  /// later. Null when none has.
  DateTime? get lastCheck {
    final value = _read()['lastCheckMs'];
    return value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  }

  set lastCheck(DateTime? value) {
    final values = _read();
    if (value == null) {
      values.remove('lastCheckMs');
    } else {
      values['lastCheckMs'] = value.millisecondsSinceEpoch;
    }
    _write(values);
  }
}
