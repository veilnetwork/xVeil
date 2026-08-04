import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../../core/log.dart';
import 'app_profile.dart';

/// App preferences, held in a FILE under the app-support directory instead of
/// the platform's system preference store (audit XV-16).
///
/// ## What was wrong with the system store
///
/// On iOS `shared_preferences` is `NSUserDefaults`, which is
/// `Library/Preferences/<bundle>.plist` — a directory iOS OWNS and backs up to
/// iCloud and to encrypted iTunes/Finder backups. The container itself is
/// already excluded (`AppDelegate.excludeAppDataFromBackup`), but that flag is
/// on Application Support and reaches nothing in Preferences. What left the
/// device in the clear was the app's whole posture: which profile is active,
/// that the profile switcher had been found at all, the proxy and VPN routing
/// policy (a JSON list of app ids, subnets and DNS servers), the notification
/// settings, the interface language.
///
/// Putting an exclusion flag on the plist — the audit's suggested remedy — does
/// not work: the system manages that directory and rewrites the file, and the
/// flag is a property of an item the app does not own.
///
/// ## And with the key names
///
/// Worse than the values, and unlisted in the audit: the profile name was
/// GLUED INTO THE KEY (`vpn_routing_policy.<profile>`), so the key list alone
/// enumerated which profiles exist on the device. In an app whose premise is
/// that a second identity cannot be proven to exist, the backup carried a
/// roster of them.
///
/// ## The fix
///
/// One file per profile, inside that profile's own directory, which is already
/// under Application Support — already excluded from backup, and already
/// readable before anything is unlocked (a preference that decides HOW to open
/// the container cannot live inside it). Because the file is per profile, the
/// key needs no profile suffix, so the names stop being a roster. Both halves,
/// one move.
///
/// Android was already sealed the other way (`allowBackup=false` plus data
/// extraction rules in the manifest); this makes the two platforms agree
/// instead of relying on one manifest attribute.
class ProfilePreferencesStore extends SharedPreferencesStorePlatform {
  ProfilePreferencesStore._(this._file, this._entries);

  /// Schema tag, so a future format change can be recognised rather than
  /// guessed at.
  static const int _version = 1;

  final File _file;

  /// value type (the `valueType` tag the plugin already hands to [setValue]) →
  /// value. Kept rather than inferred: a `double` that happens to hold 2.0 and
  /// an `int` holding 2 are the same JSON number, and `getDouble` on the wrong
  /// one throws a cast error at some unrelated call site later.
  final Map<String, ({String type, Object value})> _entries;

  /// Serializes writes so two rapid sets cannot interleave their file writes.
  Future<void> _writes = Future<void>.value();

  /// Load the store at [path] (an absent or unreadable file is an empty store —
  /// this is preferences, and refusing to start over a corrupt preference file
  /// would be the worse failure).
  static Future<ProfilePreferencesStore> load(String path) async {
    final file = File(path);
    final entries = <String, ({String type, Object value})>{};
    try {
      if (file.existsSync()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic> && json['v'] == _version) {
          final raw = json['e'];
          if (raw is Map<String, dynamic>) {
            for (final entry in raw.entries) {
              final decoded = _decode(entry.value);
              if (decoded != null) entries[entry.key] = decoded;
            }
          }
        }
      }
    } catch (e) {
      devLog(() => 'xVeil[prefs]: could not read $path, starting empty: $e');
    }
    return ProfilePreferencesStore._(file, entries);
  }

  static ({String type, Object value})? _decode(Object? encoded) {
    if (encoded is! Map<String, dynamic>) return null;
    final type = encoded['t'];
    final value = encoded['v'];
    if (type is! String || value == null) return null;
    return switch (type) {
      'Bool' when value is bool => (type: type, value: value),
      'Int' when value is int => (type: type, value: value),
      'Double' when value is num => (type: type, value: value.toDouble()),
      'String' when value is String => (type: type, value: value),
      'StringList' when value is List => (
        type: type,
        value: <String>[
          for (final item in value)
            if (item is String) item,
        ],
      ),
      _ => null,
    };
  }

  Future<void> _flush() {
    final snapshot = <String, Object>{
      'v': _version,
      'e': {
        for (final entry in _entries.entries)
          entry.key: {'t': entry.value.type, 'v': entry.value.value},
      },
    };
    final next = _writes.then((_) async {
      try {
        await _file.parent.create(recursive: true);
        // Write-then-rename: a crash mid-write must not leave a truncated file
        // that the next launch reads as "no preferences at all".
        final temp = File('${_file.path}.tmp');
        await temp.writeAsString(jsonEncode(snapshot), flush: true);
        await temp.rename(_file.path);
      } catch (e) {
        devLog(() => 'xVeil[prefs]: could not write ${_file.path}: $e');
      }
    });
    _writes = next;
    return next;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _entries[key] = (type: valueType, value: value);
    await _flush();
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _entries.remove(key);
    await _flush();
    return true;
  }

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    _entries.removeWhere(
      (key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key)),
    );
    await _flush();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final filter = parameters.filter;
    return {
      for (final entry in _entries.entries)
        if (entry.key.startsWith(filter.prefix) &&
            (filter.allowList == null || filter.allowList!.contains(entry.key)))
          entry.key: entry.value.value,
    };
  }

  static const String _defaultPrefix = 'flutter.';
}

/// Where a profile keeps its preferences.
String profilePrefsPath(String supportDir, String profile) =>
    '${AppProfiles.directory(supportDir, profile)}/xveil.prefs.json';

/// Where the ACTIVE PROFILE NAME is remembered.
///
/// Deliberately not a preference: it has to be read BEFORE the profile — and
/// therefore before the per-profile preference file — is known. A one-line file
/// beside the container, under the directory iOS is told to leave out of
/// backups, so the name of the profile in use never rides out with one.
String activeProfilePath(String supportDir) => '$supportDir/xveil.profile';

/// The remembered profile name, or null when nothing valid is recorded.
Future<String?> readRememberedProfile(String supportDir) async {
  try {
    final file = File(activeProfilePath(supportDir));
    if (!file.existsSync()) return null;
    final name = (await file.readAsString()).trim();
    return AppProfiles.isValidName(name) ? name : null;
  } catch (_) {
    return null;
  }
}

/// Remember [profile] as the one to launch next time.
Future<void> writeRememberedProfile(String supportDir, String profile) async {
  final file = File(activeProfilePath(supportDir));
  await file.parent.create(recursive: true);
  await file.writeAsString(profile, flush: true);
}

/// Install the per-profile file store as the app's preference backend, moving
/// anything the system store still holds into it first.
///
/// MIGRATION. An existing install has its preferences in `NSUserDefaults` (or
/// the Android/desktop equivalent), some of them suffixed with a profile name.
/// Each key is routed to the profile it belongs to — the suffix is matched
/// against the profile directories that actually exist, never guessed, because
/// `storage.lean_padding.v1` also ends in a dot-something — and the system
/// store is then EMPTIED. Emptying is the point: a copy left behind is a copy
/// that keeps going into the backup.
///
/// Returns the profile this launch runs on.
///
/// ⚠️ Must run before the first `SharedPreferences.getInstance()` of the
/// process: the plugin caches its map on first use, and the only way to drop
/// that cache is an API marked test-only. Called from `main` immediately after
/// the binding is up, which is the earliest anything can read a preference.
Future<String> installProfilePreferences({
  required String supportDir,
  required List<String> args,
}) async {
  final legacy = SharedPreferencesStorePlatform.instance;
  final remembered =
      await readRememberedProfile(supportDir) ??
      await _legacyString(legacy, AppProfiles.activePref);
  final profile = AppProfiles.resolve(args: args, remembered: remembered);

  final store = await ProfilePreferencesStore.load(
    profilePrefsPath(supportDir, profile),
  );
  await _migrateLegacy(legacy, supportDir, profile, store);
  // Deliberately NOT written back: `--profile` and `XVEIL_PROFILE` stay
  // one-shot, exactly as before. Only the switcher records a choice.
  SharedPreferencesStorePlatform.instance = store;
  return profile;
}

Future<String?> _legacyString(
  SharedPreferencesStorePlatform legacy,
  String key,
) async {
  try {
    final value = (await legacy.getAll())['flutter.$key'];
    return value is String ? value : null;
  } catch (_) {
    return null;
  }
}

Future<void> _migrateLegacy(
  SharedPreferencesStorePlatform legacy,
  String supportDir,
  String profile,
  ProfilePreferencesStore into,
) async {
  Map<String, Object> all;
  try {
    all = await legacy.getAll();
  } catch (e) {
    devLog(() => 'xVeil[prefs]: no legacy store to migrate: $e');
    return;
  }
  if (all.isEmpty) return;

  // Only names that exist on disk count as profile suffixes. Guessing would
  // mistake a version suffix for a profile and file the value under a profile
  // that never existed.
  // The profile being launched counts even when its directory does not exist
  // yet — a first launch on a new profile creates that directory later, and
  // without this its own keys would be filed under the default profile, i.e.
  // handed to the very profile they must stay away from.
  final known = <String>{AppProfiles.defaultName, profile};
  try {
    final dir = Directory('$supportDir/profiles');
    if (dir.existsSync()) {
      for (final entry in dir.listSync()) {
        final name = entry.path.split('/').last;
        if (AppProfiles.isValidName(name)) known.add(name);
      }
    }
  } catch (_) {
    /* an unreadable profiles dir just means no suffixes to strip */
  }

  final elsewhere = <String, Map<String, ({String type, Object value})>>{};
  for (final entry in all.entries) {
    final full = entry.key;
    if (!full.startsWith('flutter.')) continue;
    final bare = full.substring('flutter.'.length);
    // The active-profile pointer moved to its own file; the rest is settings.
    if (bare == AppProfiles.activePref) continue;

    var owner = AppProfiles.defaultName;
    var unsuffixed = bare;
    for (final name in known) {
      if (name != AppProfiles.defaultName && bare.endsWith('.$name')) {
        owner = name;
        unsuffixed = bare.substring(0, bare.length - name.length - 1);
        break;
      }
    }
    final typed = (type: _typeOf(entry.value), value: entry.value);
    if (owner == profile) {
      // Never overwrite: a value already in the file is newer than one the
      // system store kept from before the move.
      into._entries.putIfAbsent('flutter.$unsuffixed', () => typed);
    } else {
      (elsewhere[owner] ??= {})['flutter.$unsuffixed'] = typed;
    }
  }

  await into._flush();
  for (final other in elsewhere.entries) {
    final store = await ProfilePreferencesStore.load(
      profilePrefsPath(supportDir, other.key),
    );
    for (final kv in other.value.entries) {
      store._entries.putIfAbsent(kv.key, () => kv.value);
    }
    await store._flush();
  }

  // Now empty the system store. This is the half that actually closes the
  // leak: everything above only made a second copy.
  try {
    await legacy.clear();
    devLog(
      () =>
          'xVeil[prefs]: moved ${all.length} preference(s) out of the system '
          'store into per-profile files',
    );
  } catch (e) {
    devLog(() => 'xVeil[prefs]: could not empty the system store: $e');
  }
}

String _typeOf(Object value) => switch (value) {
  bool() => 'Bool',
  int() => 'Int',
  double() => 'Double',
  List<String>() => 'StringList',
  List() => 'StringList',
  _ => 'String',
};
