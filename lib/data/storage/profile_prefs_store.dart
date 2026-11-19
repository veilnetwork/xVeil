import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../../core/log.dart';
import '../../domain/profile_preferences_layout.dart';
import 'app_profile.dart';
import 'profile_preferences_file.dart';
import 'legacy_profile_preferences.dart';
import 'profile_preferences_routing.dart';

export 'profile_preferences_file.dart';
export 'profile_preferences_routing.dart';

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
  ProfilePreferencesStore._(
    this._file,
    this._entries,
    this._ownedFile,
    this._loadedSnapshot,
    this.legacyPreferences,
  );

  /// Schema tag, so a future format change can be recognised rather than
  /// guessed at.
  static const int _version = 1;

  final File _file;
  final ProfilePreferencesFile? _ownedFile;
  final bool _loadedSnapshot;
  final LegacyProfilePreferences? legacyPreferences;

  /// value type (the `valueType` tag the plugin already hands to [setValue]) →
  /// value. Kept rather than inferred: a `double` that happens to hold 2.0 and
  /// an `int` holding 2 are the same JSON number, and `getDouble` on the wrong
  /// one throws a cast error at some unrelated call site later.
  final Map<String, ({String type, Object value})> _entries;

  /// Settlement of every admitted write. Individual results go to callers.
  Future<void> _writes = Future<void>.value();
  bool _retired = false;

  /// Seal ordinary writes synchronously and join every accepted file write.
  /// Settlement is not proof of persistence; callers retain each save result.
  Future<void> retire() {
    _retired = true;
    return _writes;
  }

  /// Separate from retirement: successful settlement does not prove native
  /// release. A refused close stays owned and can be retried by its caller.
  Future<void> releaseFile() async {
    await retire();
    await _ownedFile?.close();
  }

  void _requireWritable() {
    if (_retired) throw StateError('profile preference store has retired');
  }

  /// Load the store at [path] (an absent or unreadable file is an empty store —
  /// this is preferences, and refusing to start over a corrupt preference file
  /// would be the worse failure).
  static Future<ProfilePreferencesStore> load(
    String path, {
    ProfilePreferencesFile? ownedFile,
    LegacyProfilePreferences? legacyPreferences,
  }) async {
    if (legacyPreferences != null && legacyPreferences.preferencePath != path) {
      throw const LegacyProfilePreferencesFailure();
    }
    if (ownedFile != null && ownedFile.path != path) {
      throw StateError('profile preference file owner mismatch');
    }
    final file = File(path);
    // Native admission failure is not a corrupt optional setting. Do not turn
    // a refused/dead owner into an unguarded local read or an empty backend.
    final ownedContents = ownedFile == null ? null : await ownedFile.read();
    final entries = <String, ({String type, Object value})>{};
    var loadedSnapshot = false;
    try {
      if (ownedFile != null ? ownedContents != null : file.existsSync()) {
        final json = jsonDecode(ownedContents ?? await file.readAsString());
        if (json is Map<String, dynamic> && json['v'] == _version) {
          final raw = json['e'];
          if (raw is Map<String, dynamic>) {
            loadedSnapshot = true;
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
    return ProfilePreferencesStore._(
      file,
      entries,
      ownedFile,
      loadedSnapshot,
      legacyPreferences,
    );
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
    _requireWritable();
    final snapshot = <String, Object>{
      'v': _version,
      'e': {
        for (final entry in _entries.entries)
          entry.key: {'t': entry.value.type, 'v': entry.value.value},
      },
    };
    final encoded = jsonEncode(snapshot);
    final next = _writes.then(
      (_) =>
          _ownedFile?.write(encoded) ??
          writePrivateFileAtomically(_file, encoded),
    );
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _requireWritable();
    _entries[key] = (
      type: valueType,
      value: value is List<String> ? List<String>.of(value) : value,
    );
    return _flush();
  }

  @override
  Future<bool> remove(String key) {
    _requireWritable();
    _entries.remove(key);
    return _flush();
  }

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    _requireWritable();
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
          entry.key: entry.value.value is List<String>
              ? List<String>.of(entry.value.value as List<String>)
              : entry.value.value,
    };
  }

  static const String _defaultPrefix = 'flutter.';
}

/// Where a profile keeps its preferences.
String profilePrefsPath(String supportDir, String profile) =>
    '${AppProfiles.directory(supportDir, profile)}/${ProfilePreferencesLayout.file}';

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

Future<void> _profileChoiceWrites = Future<void>.value();

/// Remember [profile] as the one to launch next time. **False means it was not
/// recorded** and the next launch will not know about it.
///
/// Written the same way as everything else here: to a temporary name, fsynced,
/// renamed, the directory fsynced, mode 0600 applied before any content exists
/// and verified afterwards. Writing straight into the file meant a crash part
/// way through left a zero-length pointer — which reads as "no profile
/// remembered" and silently sends the next launch to the default one (audit
/// X-05).
Future<bool> writeRememberedProfile(String supportDir, String profile) {
  // Each write for this file uses the same temporary name. Queue writes in
  // this isolate so the next one opens it only after the previous one settles.
  final write = _profileChoiceWrites.then(
    (_) => writeProfileChoiceAtomically(
      File(activeProfilePath(supportDir)),
      profile,
    ),
  );
  _profileChoiceWrites = write.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {},
  );
  return write;
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
///
/// [environment] defaults to the process environment. It is a parameter for the
/// same reason [AppProfiles.resolve] takes one: `XVEIL_PROFILE` must be shown
/// to stay one-shot, and a test cannot set a variable on its own process.
/// [legacyBackend] is the retained original platform source for a released
/// fresh lifetime. It avoids migrating from the now-retired file backend.
Future<String> installProfilePreferences({
  required String supportDir,
  required List<String> args,
  Map<String, String>? environment,
  OpenProfilePreferencesFile? openOwnedFile,
  void Function(String path)? validateSelectedFile,
  void Function(LegacyProfilePreferences source)? onResolvedLegacySource,
  SharedPreferencesStorePlatform? legacyBackend,
}) async {
  final legacy = legacyBackend ?? SharedPreferencesStorePlatform.instance;
  final pointer = await readRememberedProfile(supportDir);
  final legacySnapshot = await _readLegacyPreferences(legacy);
  final savedChoice = legacySnapshot['flutter.${AppProfiles.activePref}'];
  final legacyPointer = savedChoice is String ? savedChoice : null;
  final resolved = AppProfiles.resolveWithSource(
    args: args,
    environment: environment,
    pointer: pointer,
    legacyPointer: legacyPointer,
  );
  final profile = resolved.name;
  final selectedPath = profilePrefsPath(supportDir, profile);
  validateSelectedFile?.call(selectedPath);
  final env = environment ?? Platform.environment;
  final override = env['XVEIL_STORE_PATH'];
  final legacySource = openOwnedFile == null
      ? null
      : LegacyProfilePreferences(
          backend: legacy,
          supportDirectory: supportDir,
          profile: profile,
          legacyPath: override != null && override.isNotEmpty
              ? override
              : AppProfiles.storePath(supportDir, profile),
        );
  if (legacySource != null) onResolvedLegacySource?.call(legacySource);
  // Resolution above is read-only. In managed builds the native owner must
  // exist before pointer migration, any preference read or any migration write.
  final ownedFile = await openOwnedFile?.call(selectedPath);
  ProfilePreferencesStore? installed;
  try {
    final store = installed = await ProfilePreferencesStore.load(
      selectedPath,
      ownedFile: ownedFile,
      legacyPreferences: legacySource,
    );
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

    await _migrateLegacy(
      legacy,
      legacySnapshot,
      supportDir,
      profile,
      store,
      mayClearLegacy: pointerSafe,
      openOwnedFile: openOwnedFile,
    );
    SharedPreferencesStorePlatform.instance = store;
    return profile;
  } catch (_) {
    try {
      await (installed?.releaseFile() ?? ownedFile?.close());
    } catch (closeError, closeStack) {
      // The native owner retains a failed close for the next retirement
      // attempt. Keep the original failure for startup diagnostics.
      devLog(
        () =>
            'xVeil[prefs]: close after failed install: $closeError\n$closeStack',
      );
    }
    rethrow;
  }
}

/// [installProfilePreferences], and — when it cannot be done — an EMPTY
/// IN-MEMORY store rather than the platform's system one.
///
/// The install is a sequence of file operations that ends, on its LAST line,
/// with the assignment that swaps the backend. Anything that throws before that
/// line (a `path_provider` that has no answer on this platform, an app-support
/// directory that cannot be created, a read-only volume) used to be caught in
/// `main` under "never fatal: preferences are conveniences" — and left
/// `SharedPreferencesStorePlatform.instance` as the plugin's default.
///
/// That default IS the system store, which is the thing being escaped. Every
/// setting written afterwards goes back into `NSUserDefaults`, back into iCloud
/// and encrypted backups, and — because the profile name is glued into the key
/// names on that path — back to publishing a roster of which profiles exist.
/// One failed `mkdir` silently undid the whole of audit XV-16.
///
/// So the failure is taken TOWARDS privacy instead of away from it: an empty
/// in-memory backend. The app starts, every screen works, and settings changed
/// this session are forgotten when it exits. That is a bad session; the
/// alternative is a leak. The report's own remedy — refuse to write, or refuse
/// to unlock — was rejected: it breaks the launch and confronts the user with a
/// plugin failure they can do nothing about.
///
/// [supportDir] is a callback rather than a value so that the directory lookup
/// is inside the guard too. It is the single most likely thing here to fail on
/// a platform where the plugin is missing, and taking it outside would leave
/// exactly the hole this closes.
Future<String> installProfilePreferencesOrFallback({
  required Future<String> Function() supportDir,
  required List<String> args,
  Map<String, String>? environment,
  void Function(Object error, StackTrace stack)? onError,
  OpenProfilePreferencesFile? openOwnedFile,
  void Function(String path)? validateSelectedFile,
  void Function(LegacyProfilePreferences source)? onResolvedLegacySource,
  SharedPreferencesStorePlatform? legacyBackend,
}) async {
  try {
    return await installProfilePreferences(
      supportDir: await supportDir(),
      args: args,
      environment: environment,
      openOwnedFile: openOwnedFile,
      validateSelectedFile: validateSelectedFile,
      onResolvedLegacySource: onResolvedLegacySource,
      legacyBackend: legacyBackend,
    );
  } catch (e, st) {
    if (openOwnedFile != null) rethrow;
    onError?.call(e, st);
    installEphemeralPreferences();
    return AppProfiles.defaultName;
  }
}

/// Put an empty in-memory backend in place of the system store.
///
/// A no-op when the real file store is already installed, so this can never
/// undo a successful install — the only throw that could reach it comes from
/// before the assignment, but "could not have happened" is a worse guarantee
/// than "cannot".
void installEphemeralPreferences() {
  if (SharedPreferencesStorePlatform.instance is ProfilePreferencesStore) {
    return;
  }
  SharedPreferencesStorePlatform.instance =
      InMemorySharedPreferencesStore.empty();
}

Future<Map<String, Object>> _readLegacyPreferences(
  SharedPreferencesStorePlatform legacy,
) async {
  try {
    return Map.of(await legacy.getAll());
  } catch (error) {
    devLog(() => 'xVeil[prefs]: no legacy store to migrate: $error');
    return const {};
  }
}

Future<void> _migrateLegacy(
  SharedPreferencesStorePlatform legacy,
  Map<String, Object> snapshot,
  String supportDir,
  String profile,
  ProfilePreferencesStore into, {
  required bool mayClearLegacy,
  OpenProfilePreferencesFile? openOwnedFile,
}) async {
  if (snapshot.isEmpty) return;

  // Only names that exist on disk count as profile suffixes. Guessing would
  // mistake a version suffix for a profile and file the value under a profile
  // that never existed.
  // The profile being launched counts even when its directory does not exist
  // yet — a first launch on a new profile creates that directory later, and
  // without this its own keys would be filed under the default profile, i.e.
  // handed to the very profile they must stay away from.
  final known = <String>{AppProfiles.defaultName, profile};
  final dir = Directory('$supportDir/profiles');
  try {
    for (final entry in dir.listSync(followLinks: false)) {
      final name = lastPathSegment(entry.path);
      if (AppProfiles.isValidName(name)) known.add(name);
    }
  } on FileSystemException catch (error) {
    // An absent directory is normal on a first launch. If listing was
    // refused, keep the legacy values until their profile can be determined.
    if (error is! PathNotFoundException ||
        FileSystemEntity.typeSync(dir.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      devLog(() => 'xVeil[prefs]: deferring migration: profiles unavailable');
      return;
    }
  }

  final selectedCount = into._entries.length;
  final elsewhere = <String, Map<String, ({String type, Object value})>>{};
  final migratedKeys = <String>{};
  for (final entry in snapshot.entries) {
    final full = entry.key;
    if (!full.startsWith('flutter.')) continue;
    migratedKeys.add(full);
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

  // All newly imported keys require a successful write before the legacy
  // source can be cleared. An unchanged snapshot needs no second write.
  final current = into._loadedSnapshot && into._entries.length == selectedCount;
  var migrated = current || await into._flush();
  for (final other in elsewhere.entries) {
    final path = profilePrefsPath(supportDir, other.key);
    ProfilePreferencesFile? owner;
    ProfilePreferencesStore? store;
    try {
      owner = await openOwnedFile?.call(path);
      store = await ProfilePreferencesStore.load(path, ownedFile: owner);
      final persistedCount = store._entries.length;
      for (final kv in other.value.entries) {
        store._entries.putIfAbsent(kv.key, () => kv.value);
      }
      if (store._entries.length != persistedCount && !await store._flush()) {
        migrated = false;
      }
    } catch (_) {
      // A refused destination must not be resurrected by migration. Retain
      // the complete legacy source so a later admitted launch can try again.
      migrated = false;
    } finally {
      try {
        await (store?.releaseFile() ?? owner?.close());
      } catch (error, stack) {
        // The native owner keeps an unconfirmed close available for retry.
        // Preserve the migration source while the selected profile starts.
        migrated = false;
        devLog(
          () => 'xVeil[prefs]: close after profile migration: $error\n$stack',
        );
      }
    }
  }

  if (!migrated || !mayClearLegacy) {
    devLog(
      () =>
          'xVeil[prefs]: NOT emptying the system store — '
          '${migrated ? 'the active-profile pointer could not be carried over' : 'a per-profile migration is incomplete'}. '
          'A second copy in the backup is bad; losing the only copy is worse, '
          'and the next launch can try again.',
    );
    return;
  }

  // Remove only the keys covered by this migration. The platform store can
  // have gained new keys while the destination files were being written.
  if (migratedKeys.isEmpty) return;
  try {
    if (await legacy.clearWithParameters(
      ClearParameters(
        filter: PreferencesFilter(prefix: 'flutter.', allowList: migratedKeys),
      ),
    )) {
      devLog(
        () =>
            'xVeil[prefs]: moved ${migratedKeys.length} preference(s) out of the system '
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
