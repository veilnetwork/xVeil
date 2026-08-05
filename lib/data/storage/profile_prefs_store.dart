import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../../core/log.dart';
import '../../core/posix_file_facts.dart';
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

  /// Persist the current entries. **False means nothing reached the disk.**
  ///
  /// This used to catch every exception, log it and hand its caller a `true`
  /// anyway — so a full disk, a read-only mount or a permission error read as a
  /// successful save, and the migration below emptied the only other copy on
  /// the strength of it (audit X-02).
  Future<bool> _flush() {
    final snapshot = <String, Object>{
      'v': _version,
      'e': {
        for (final entry in _entries.entries)
          entry.key: {'t': entry.value.type, 'v': entry.value.value},
      },
    };
    final next = _writes.then(
      (_) => writePrivateFileAtomically(_file, jsonEncode(snapshot)),
    );
    _writes = next;
    return next;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _entries[key] = (type: valueType, value: value);
    return _flush();
  }

  @override
  Future<bool> remove(String key) {
    _entries.remove(key);
    return _flush();
  }

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    final filter = parameters.filter;
    _entries.removeWhere(
      (key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key)),
    );
    return _flush();
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

/// Owner-only permissions for what this file writes: `0600` on the preference
/// and pointer files, `0700` on the directory holding them.
///
/// These files are the app's SECURITY POSTURE in the clear — which profile is
/// active, the VPN routing policy with its app ids and subnets, whether the
/// switcher has been found. They must be readable before anything is unlocked,
/// so they cannot go inside the container; the least that can be asked of them
/// is that no other local account can read them (audit X-05).
const int _ownerOnlyFile = 0x180; // 0600
const int _ownerOnlyDir = 0x1C0; // 0700

/// Whether a failure to make these files owner-only must fail the write.
///
/// The same split, for the same reason, as `runtimeDirMustBePrivate` in the
/// veil stack. On macOS and Linux the app-support path can sit on a filesystem
/// other local accounts share, so a posture file at a permissive umask is a
/// real exposure and writing it is worse than not writing it. On Android and
/// iOS the app sandbox is already the boundary, and on Windows access is
/// governed by the profile ACL, which a POSIX mode cannot describe and this
/// code does not attempt to set — refusing there would trade a guarantee those
/// platforms already give for a broken settings screen.
bool prefsFilesMustBePrivate() => Platform.isMacOS || Platform.isLinux;

/// Create [dir] and make it owner-only.
///
/// Best effort on purpose: the file mode below is the check that decides, and
/// for the default profile this directory is the app-support directory itself,
/// which the platform already places inside the app's own tree.
Future<void> _ensurePrivateDir(Directory dir) async {
  await dir.create(recursive: true);
  if (Platform.isWindows) return;
  final rc = posixChmod(dir.path, _ownerOnlyDir);
  if (rc != null && rc != 0) {
    devLog(() => 'xVeil[prefs]: could not restrict ${dir.path} to 0700');
  }
}

/// Make [path] readable by its owner ONLY, and PROVE it.
///
/// Three separate things, none of which the other two cover:
///
///   * `chmod` exiting zero means the filesystem accepted the request. Mounted
///     shares and some vendor mounts accept it and keep the old mode, so the
///     mode is read back rather than assumed.
///   * the read-back is an `lstat`, so a symlink swapped in at the name between
///     the create and here is seen as a symlink instead of being followed.
///   * the owner is checked against this process, which is what catches a file
///     that is now somebody else's.
///
/// Goes through libc, not `Process.run('chmod', …)`: a bare command name is
/// resolved through PATH, which is the substitutable oracle audit C-01 was
/// about.
bool _restrictToOwner(String path) {
  if (Platform.isWindows) return true;
  final rc = posixChmod(path, _ownerOnlyFile);
  if (!prefsFilesMustBePrivate()) return true;
  if (rc == null || rc != 0) {
    devLog(() => 'xVeil[prefs]: chmod 0600 refused $path');
    return false;
  }
  final facts = posixLstat(path);
  if (facts == null) {
    devLog(() => 'xVeil[prefs]: could not read the mode back for $path');
    return false;
  }
  if (!facts.isRegularFile) {
    devLog(() => 'xVeil[prefs]: $path is not a regular file, refusing to write');
    return false;
  }
  if (facts.permissions != _ownerOnlyFile) {
    devLog(
      () =>
          'xVeil[prefs]: $path is ${facts.permissions.toRadixString(8)} after '
          'chmod, not 600',
    );
    return false;
  }
  final euid = posixEuid();
  if (euid != null && facts.uid != euid) {
    devLog(() => 'xVeil[prefs]: $path is not owned by this process');
    return false;
  }
  return true;
}

/// Write [contents] to [file] durably, privately and atomically — or return
/// **false**, which is the entire point of the function.
///
/// The version this replaces caught every exception, logged it, and let its
/// callers report success (audit X-02); the migration then emptied the only
/// other copy of the data on the strength of that report. What it now
/// establishes before it says yes:
///
///   * **atomic** — the bytes land under a temporary name and are renamed over
///     the target, so a crash mid-write cannot leave a truncated file that the
///     next launch reads as "no preferences at all";
///   * **durable** — the file is fsynced before the rename and the DIRECTORY
///     after it. Syncing only the file makes the CONTENT survive a power cut
///     while the rename that gave it its name does not (audit X-02);
///   * **private** — the mode is applied to the temporary while it is still
///     empty, so the values never exist on disk at the process umask, not even
///     between two syscalls (audit X-05);
///   * **actually there** — the file is read back and compared. A filesystem
///     that accepted every call is not the same thing as a filesystem that
///     kept the result.
Future<bool> writePrivateFileAtomically(File file, String contents) async {
  final temp = File('${file.path}.tmp');
  try {
    await _ensurePrivateDir(file.parent);
    // Never write THROUGH a link someone else planted at the temporary name:
    // that is how a 0600 file ends up being somebody else's file, with our
    // posture in it. A directory in the way is not something to clear out.
    final planted = FileSystemEntity.typeSync(temp.path, followLinks: false);
    if (planted == FileSystemEntityType.link) {
      await Link(temp.path).delete();
    } else if (planted == FileSystemEntityType.directory) {
      devLog(() => 'xVeil[prefs]: ${temp.path} is a directory, refusing');
      return false;
    }

    // Create empty, restrict, THEN fill. Reversing these two would put the
    // values on disk at the umask for as long as the chmod takes to run, and
    // [_restrictToOwner]'s lstat is also what catches a link that won the race
    // between the type check above and this open.
    final handle = await temp.open(mode: FileMode.writeOnly);
    try {
      if (!_restrictToOwner(temp.path)) return false;
      await handle.writeString(contents);
      await handle.flush(); // fsync(2) on the file
    } finally {
      await handle.close();
    }

    await temp.rename(file.path);
    // The rename itself, made durable. Null just means no libc binding here.
    posixFsyncDir(file.parent.path);
    if (!_restrictToOwner(file.path)) return false;

    // Read it back. This is the difference between "no call reported an error"
    // and "the bytes are there".
    if (await file.readAsString() != contents) {
      devLog(() => 'xVeil[prefs]: ${file.path} did not read back as written');
      return false;
    }
    return true;
  } catch (e) {
    devLog(() => 'xVeil[prefs]: could not write ${file.path}: $e');
    try {
      if (temp.existsSync()) await temp.delete();
    } catch (_) {
      /* the temporary is litter, not a reason to fail differently */
    }
    return false;
  }
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

/// Remember [profile] as the one to launch next time. **False means it was not
/// recorded** and the next launch will not know about it.
///
/// Written the same way as everything else here: to a temporary name, fsynced,
/// renamed, the directory fsynced, mode 0600 applied before any content exists
/// and verified afterwards. Writing straight into the file meant a crash part
/// way through left a zero-length pointer — which reads as "no profile
/// remembered" and silently sends the next launch to the default one (audit
/// X-05).
Future<bool> writeRememberedProfile(String supportDir, String profile) =>
    writePrivateFileAtomically(File(activeProfilePath(supportDir)), profile);

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
///
/// [environment] defaults to the process environment. It is a parameter for the
/// same reason [AppProfiles.resolve] takes one: `XVEIL_PROFILE` must be shown
/// to stay one-shot, and a test cannot set a variable on its own process.
Future<String> installProfilePreferences({
  required String supportDir,
  required List<String> args,
  Map<String, String>? environment,
}) async {
  final legacy = SharedPreferencesStorePlatform.instance;
  final pointer = await readRememberedProfile(supportDir);
  final legacyPointer = await _legacyString(legacy, AppProfiles.activePref);
  final resolved = AppProfiles.resolveWithSource(
    args: args,
    environment: environment,
    pointer: pointer,
    legacyPointer: legacyPointer,
  );
  final profile = resolved.name;

  // CARRY THE OLD POINTER ACROSS, before anything empties the store it lives
  // in. Skipping this is what audit X-01 found: the first launch after the
  // upgrade read `profile.active.v1` from the system store and picked the right
  // profile, the migration then emptied that store without copying the pointer
  // anywhere, and the SECOND launch — with neither pointer left — silently
  // dropped the user into the default profile, a different identity with a
  // different posture, and offered onboarding for it.
  //
  // What is carried is the OLD POINTER'S OWN VALUE, never the resolved name.
  // That is what keeps `--profile` and `XVEIL_PROFILE` one-shot: launching with
  // a flag still runs that profile for this process only, and still leaves the
  // remembered choice exactly as the user left it. It is also why this does not
  // wait for the flag-less case — clearing the store destroys the pointer no
  // matter which source won this particular launch.
  //
  // The question asked is "would the OLD pointer decide, had this launch been
  // given no instructions" — deliberately not "did it decide this time". An
  // empty `args`/`environment` is passed for exactly that reason: a source that
  // answers here can only be [ProfileSource.legacyPointer], and anything else
  // means the old pointer held nothing this build would accept and there is
  // nothing to lose by emptying the store.
  final carried = pointer == null
      ? AppProfiles.resolveWithSource(
          args: const [],
          environment: const {},
          legacyPointer: legacyPointer,
        )
      : null;
  var pointerSafe = true;
  if (carried != null && carried.source == ProfileSource.legacyPointer) {
    pointerSafe = await writeRememberedProfile(supportDir, carried.name);
    if (!pointerSafe) {
      devLog(
        () =>
            'xVeil[prefs]: could not carry the remembered profile into '
            '${activeProfilePath(supportDir)} — leaving the system store alone '
            'rather than forgetting which profile this install runs on',
      );
    }
  }

  final store = await ProfilePreferencesStore.load(
    profilePrefsPath(supportDir, profile),
  );
  await _migrateLegacy(
    legacy,
    supportDir,
    profile,
    store,
    mayClearLegacy: pointerSafe,
  );
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

/// The last segment of [path], the way the HOST names paths.
///
/// `split('/').last` was wrong on Windows, where `Directory.listSync` hands
/// back `C:\…\profiles\decoy` and the whole string came back as the "name" — so
/// no directory there was ever recognised as a profile and every suffixed key
/// migrated into the default profile, which is precisely the profile those
/// values must stay away from (audit X-04).
///
/// Only Windows treats `\` as a separator. On POSIX a backslash is an ordinary
/// character in a file name, and splitting on it there would invent segments
/// that do not exist. [windows] is a parameter rather than a read of
/// `Platform`, because a Windows path is not something a test on this machine
/// can otherwise produce.
String lastPathSegment(String path, {bool? windows}) {
  var cut = path.lastIndexOf('/');
  if (windows ?? Platform.isWindows) {
    final back = path.lastIndexOf('\\');
    if (back > cut) cut = back;
  }
  return cut < 0 ? path : path.substring(cut + 1);
}

/// Which profile a legacy key belongs to, and the key with the suffix removed.
///
/// LONGEST suffix wins, which is why [known] is sorted here rather than
/// iterated in whatever order it arrived. With profiles `a` and `x.a` both on
/// the device, the first match against `proxy_routing.x.a` could be `.a` — and
/// the value, a routing policy, went to profile `a` under the invented key
/// `proxy_routing.x` (audit X-04). Only the longest match names a real profile;
/// every shorter one is a suffix of that name.
({String owner, String key}) routeLegacyKey(String bare, Set<String> known) {
  final byLength = known.where((name) => name != AppProfiles.defaultName).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final name in byLength) {
    if (bare.endsWith('.$name')) {
      return (
        owner: name,
        key: bare.substring(0, bare.length - name.length - 1),
      );
    }
  }
  return (owner: AppProfiles.defaultName, key: bare);
}

Future<void> _migrateLegacy(
  SharedPreferencesStorePlatform legacy,
  String supportDir,
  String profile,
  ProfilePreferencesStore into, {
  required bool mayClearLegacy,
}) async {
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
        final name = lastPathSegment(entry.path);
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
    // The active-profile pointer has its own file and was carried there before
    // this ran; the rest is settings.
    if (bare == AppProfiles.activePref) continue;

    final routed = routeLegacyKey(bare, known);
    final typed = (type: _typeOf(entry.value), value: entry.value);
    if (routed.owner == profile) {
      // Never overwrite: a value already in the file is newer than one the
      // system store kept from before the move.
      into._entries.putIfAbsent('flutter.${routed.key}', () => typed);
    } else {
      (elsewhere[routed.owner] ??= {})['flutter.${routed.key}'] = typed;
    }
  }

  // EVERY destination has to be on disk before the source is emptied. A single
  // failed write used to be logged and ignored, and the clear below then
  // destroyed the only remaining copy of settings that decide how the container
  // is opened (audit X-02).
  var written = await into._flush();
  for (final other in elsewhere.entries) {
    final store = await ProfilePreferencesStore.load(
      profilePrefsPath(supportDir, other.key),
    );
    for (final kv in other.value.entries) {
      store._entries.putIfAbsent(kv.key, () => kv.value);
    }
    if (!await store._flush()) written = false;
  }

  if (!written || !mayClearLegacy) {
    devLog(
      () =>
          'xVeil[prefs]: NOT emptying the system store — '
          '${written ? 'the active-profile pointer could not be carried over' : 'a per-profile file could not be written'}. '
          'A second copy in the backup is bad; losing the only copy is worse, '
          'and the next launch can try again.',
    );
    return;
  }

  // Now empty the system store. This is the half that actually closes the
  // leak: everything above only made a second copy.
  try {
    if (await legacy.clear()) {
      devLog(
        () =>
            'xVeil[prefs]: moved ${all.length} preference(s) out of the system '
            'store into per-profile files',
      );
    } else {
      // The old code awaited this and logged success regardless, so a store
      // that declined to clear left the whole posture in the backup under a
      // log line saying it had been removed.
      devLog(
        () =>
            'xVeil[prefs]: the system store REFUSED to clear — the preferences '
            'are still in it, and still in the backup',
      );
    }
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
