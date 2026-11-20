import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_linux/shared_preferences_linux.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

import '../../core/log.dart';
import '../../domain/profile_preferences_layout.dart';
import 'app_profile.dart';
import 'profile_preferences_file.dart';
import 'legacy_profile_preferences.dart';
import 'profile_preferences_routing.dart';

export 'profile_preferences_file.dart';
export 'profile_preferences_routing.dart';

typedef _PreferenceEntry = ({String type, Object value, bool legacyCopy});
typedef _PreferenceEntries = Map<String, _PreferenceEntry>;
const _legacyActiveKey = 'flutter.${AppProfiles.activePref}';

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
    this.legacyPreferences,
  );

  /// Schema tag, so a future format change can be recognised rather than
  /// guessed at.
  static const int _version = 1;

  final File _file;
  final ProfilePreferencesFile? _ownedFile;
  final LegacyProfilePreferences? legacyPreferences;

  /// value type (the `valueType` tag the plugin already hands to [setValue]) →
  /// value. Kept rather than inferred: a `double` that happens to hold 2.0 and
  /// an `int` holding 2 are the same JSON number, and `getDouble` on the wrong
  /// one throws a cast error at some unrelated call site later.
  _PreferenceEntries _entries;

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

  /// Load the store at [path]. A native owner refuses damaged or unsupported
  /// snapshots. The unowned legacy backend still recovers invalid JSON.
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
    // Admission failures from a native owner must propagate. The legacy
    // backend still tolerates unreadable preferences during startup.
    final contents = ownedFile != null
        ? await ownedFile.read()
        : await _readUnowned(file).onError<FileSystemException>((_, _) => null);
    final entries = _decodeSnapshot(
      contents,
      recoverInvalidJson: ownedFile == null,
    );
    return ProfilePreferencesStore._(
      file,
      entries ?? {},
      ownedFile,
      legacyPreferences,
    );
  }

  static Future<String?> _readUnowned(File file) async {
    return file.existsSync() ? file.readAsString() : null;
  }

  Future<String?> _readContents() => _ownedFile?.read() ?? _readUnowned(_file);

  static _PreferenceEntries? _decodeSnapshot(
    String? contents, {
    bool recoverInvalidJson = false,
  }) {
    if (contents == null) return null;
    final Object? snapshot;
    try {
      snapshot = jsonDecode(contents);
    } on FormatException {
      if (recoverInvalidJson) return null;
      throw const ProfilePreferencesFormatFailure(
        ProfilePreferencesFormatReason.invalidJson,
      );
    }
    if (snapshot is! Map<String, dynamic> || snapshot['v'] != _version) {
      throw const ProfilePreferencesFormatFailure(
        ProfilePreferencesFormatReason.unsupportedVersion,
      );
    }
    final raw = snapshot['e'];
    if (raw is! Map<String, dynamic>) {
      throw const ProfilePreferencesFormatFailure(
        ProfilePreferencesFormatReason.invalidEntries,
      );
    }
    final entries = _PreferenceEntries();
    for (final entry in raw.entries) {
      final value = entry.value;
      final decoded =
          value is Map<String, dynamic> &&
              (!value.containsKey('legacyCopy') || value['legacyCopy'] is bool)
          ? _decodeValue(
              value['t'],
              value['v'],
              legacyCopy: value['legacyCopy'] == true,
            )
          : null;
      if (decoded == null) {
        throw const ProfilePreferencesFormatFailure(
          ProfilePreferencesFormatReason.invalidEntries,
        );
      }
      entries[entry.key] = decoded;
    }
    return entries;
  }

  /// Safety decisions must see the file even when this process has a cached
  /// snapshot. Use the existing native owner and wait for accepted writes.
  Future<String?> readPersistedString(String key) async {
    _requireWritable();
    await _writes;
    _requireWritable();
    final entries = _decodeSnapshot(await _readContents());
    final entry = entries?['$_defaultPrefix$key'];
    return entry?.type == 'String' ? entry!.value as String : null;
  }

  static _PreferenceEntry? _decodeValue(
    Object? type,
    Object? value, {
    bool legacyCopy = false,
  }) {
    if (type is! String) return null;
    final normalized = switch (type) {
      'Bool' when value is bool => value,
      'Int' when value is int => value,
      'Double' when value is num && value.isFinite => value.toDouble(),
      'String' when value is String => value,
      'StringList'
          when value is List && value.every((item) => item is String) =>
        List<String>.from(value),
      _ => null,
    };
    return normalized == null
        ? null
        : (type: type, value: normalized, legacyCopy: legacyCopy);
  }

  /// Apply one operation to the latest file. A concurrent commit invalidates
  /// the comparison, so retry the operation against a fresh snapshot.
  Future<bool> _edit(
    FutureOr<bool> Function(_PreferenceEntries entries) change, {
    bool ensureFile = false,
  }) {
    _requireWritable();
    final next = _writes.then((_) async {
      final elapsed = Stopwatch()..start();
      while (true) {
        final raw = await _readContents();
        final snapshot = _decodeSnapshot(
          raw,
          recoverInvalidJson: _ownedFile == null,
        );
        final entries = snapshot ?? _PreferenceEntries();
        if (!await change(entries) && (!ensureFile || snapshot != null)) {
          _entries = entries;
          return true;
        }
        final encoded = jsonEncode({
          'v': _version,
          'e': {
            for (final entry in entries.entries)
              entry.key: {
                't': entry.value.type,
                'v': entry.value.value,
                if (entry.value.legacyCopy) 'legacyCopy': true,
              },
          },
        });
        final saved =
            await (_ownedFile?.compareAndWrite(raw, encoded) ??
                compareAndWritePrivatePreferences(_file, raw, encoded));
        if (saved != null) {
          if (saved) _entries = entries;
          return saved;
        }
        if (elapsed.elapsed >= const Duration(seconds: 2)) return false;
      }
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _requireWritable();
    final entry = _decodeValue(valueType, value);
    if (entry == null) return Future.value(false);
    return _edit((entries) {
      entries[key] = entry;
      return true;
    });
  }

  @override
  Future<bool> remove(String key) => _edit((entries) {
    entries.remove(key);
    return true;
  });

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    final filter = parameters.filter;
    final allowList = filter.allowList?.toSet();
    return _edit((entries) {
      entries.removeWhere(
        (key, _) =>
            key.startsWith(filter.prefix) &&
            (allowList == null || allowList.contains(key)),
      );
      return true;
    });
  }

  Future<bool> _importLegacy(
    _PreferenceEntries imported,
    SharedPreferencesStorePlatform legacy,
    String profile, {
    bool ensureFile = false,
  }) => _edit((entries) async {
    Map<String, Object>? liveSource;
    var changed = false;
    for (final entry in imported.entries) {
      final existing = entries[entry.key];
      if (existing != null) {
        if (!existing.legacyCopy ||
            existing.type == entry.value.type &&
                _sameLegacyValue(existing.value, entry.value.value)) {
          continue;
        }
        // Read the source after reading the destination. An older migration
        // may still hold a snapshot whose value was already replaced or
        // removed. A concurrent destination write also forces a new check.
        liveSource ??= await _readLegacyPreferences(legacy);
        final sourceKey = profile == AppProfiles.defaultName
            ? entry.key
            : '${entry.key}.$profile';
        if (!_sameLegacyValue(liveSource[sourceKey], entry.value.value)) {
          continue;
        }
      }
      entries[entry.key] = entry.value;
      changed = true;
    }
    return changed;
  }, ensureFile: ensureFile);

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

/// The remembered profile name, or null if absent or unusable. With
/// [requireValid], a malformed choice raises [ProfileChoiceReadFailure].
Future<String?> readRememberedProfile(
  String supportDir, {
  bool requireValid = false,
}) => readStartupProfileChoice(
  File(activeProfilePath(supportDir)),
  requireValid: requireValid,
);

Future<void> _profileChoiceWrites = Future<void>.value();

/// Remember [profile] as the one to launch next time. False means the write
/// could not be confirmed. With [onlyIfUnset], a valid choice already on disk
/// also counts as success and a malformed choice is left in place.
///
/// Written the same way as everything else here: to a temporary name, fsynced,
/// renamed, the directory fsynced, mode 0600 applied before any content exists
/// and verified afterwards. Writing straight into the file meant a crash part
/// way through left a zero-length pointer — which reads as "no profile
/// remembered" and silently sends the next launch to the default one (audit
/// X-05).
Future<bool> writeRememberedProfile(
  String supportDir,
  String profile, {
  bool onlyIfUnset = false,
}) {
  // Each write for this file uses the same temporary name. Queue writes in
  // this isolate so the next one opens it only after the previous one settles.
  final write = _profileChoiceWrites.then(
    (_) => writeProfileChoiceAtomically(
      File(activeProfilePath(supportDir)),
      profile,
      onlyIfUnset: onlyIfUnset,
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
  Future<String?> readChoice() =>
      readRememberedProfile(supportDir, requireValid: openOwnedFile != null);
  String? pointer;
  var pointerSafe = true;
  try {
    pointer = await readChoice();
  } on ProfileChoiceReadFailure {
    final explicit = AppProfiles.resolveWithSource(
      args: args,
      environment: environment,
    );
    if (explicit.source == ProfileSource.fallbackDefault) rethrow;
    // An explicit launch can proceed while leaving the saved choice and the
    // legacy source available for a future ordinary launch.
    pointerSafe = false;
  }
  final choiceWithoutLegacy = AppProfiles.resolveWithSource(
    args: args,
    environment: environment,
    pointer: pointer,
  );
  // During upgrade the platform store may still hold the only saved choice.
  // A read refusal is not evidence that the default profile was selected.
  final needsSavedChoice =
      choiceWithoutLegacy.source == ProfileSource.fallbackDefault;
  var legacySnapshot = const <String, Object>{};
  try {
    legacySnapshot = await _readLegacyPreferences(
      legacy,
      requiredForChoice: openOwnedFile != null && needsSavedChoice,
    );
  } on ProfileChoiceReadFailure {
    // A concurrent launch may have carried the only old choice while this
    // reader was waiting. If a new choice is available, leave migration for
    // a launch that can read the old source.
    pointer = await readChoice();
    if (pointer == null) rethrow;
  }
  if (needsSavedChoice) {
    // The first read and the legacy snapshot are not atomic. Read the newer
    // record again before choosing a profile or opening its storage.
    pointer ??= await readChoice();
  }
  final savedChoice = legacySnapshot[_legacyActiveKey];
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
    final carried = pointerSafe && pointer == null
        ? AppProfiles.resolveWithSource(
            args: const [],
            environment: const {},
            legacyPointer: legacyPointer,
          )
        : null;
    if (carried != null && carried.source == ProfileSource.legacyPointer) {
      final currentChoice = (await _readLegacyPreferences(
        legacy,
      ))[_legacyActiveKey];
      pointerSafe =
          _sameLegacyValue(savedChoice, currentChoice) &&
          await writeRememberedProfile(
            supportDir,
            carried.name,
            onlyIfUnset: true,
          );
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
    if (openOwnedFile != null ||
        e is ProfileChoiceReadFailure ||
        e is ProfilePreferencesFormatFailure) {
      rethrow;
    }
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
  SharedPreferencesStorePlatform legacy, {
  bool requiredForChoice = false,
}) async {
  try {
    Future<Map<String, Object>> read() async {
      if (requiredForChoice &&
          (legacy is SharedPreferencesLinux ||
              legacy is SharedPreferencesWindows)) {
        // Both desktop plugins turn an empty or non-object file into an
        // empty map. For startup that cannot distinguish a damaged choice
        // from a clean install. Use the same platform path and read it once.
        final support = await getApplicationSupportDirectory();
        return readDesktopLegacyPreferences(
          File.fromUri(support.uri.resolve('shared_preferences.json')),
        );
      }
      return _freshLegacyReader(legacy).getAll();
    }
    final snapshot = requiredForChoice
        ? await retryProfileChoiceRead(
            read,
            isAbsent: (data) => data.isEmpty,
          )
        : await read();
    return {
      for (final entry in snapshot.entries)
        entry.key: switch (entry.value) {
          final List values => List<Object?>.of(values),
          final value => value,
        },
    };
  } catch (error, stack) {
    if (requiredForChoice) {
      Error.throwWithStackTrace(
        ProfileChoiceReadFailure(
          busy: isWindowsFileSharingViolation(error),
          fromLegacy: true,
        ),
        stack,
      );
    }
    devLog(() => 'xVeil[prefs]: no legacy store to migrate: $error');
    return const {};
  }
}

/// The legacy desktop plugins cache their file after the first read. Migration
/// uses fresh instances so a second process's changes can be observed.
SharedPreferencesStorePlatform _freshLegacyReader(
  SharedPreferencesStorePlatform legacy,
) => switch (legacy) {
  SharedPreferencesLinux() => SharedPreferencesLinux(),
  SharedPreferencesWindows() => SharedPreferencesWindows(),
  _ => legacy,
};

bool _sameLegacyValue(Object? a, Object? b) {
  if (a is List && b is List) return listEquals(a, b);
  return a?.runtimeType == b?.runtimeType && a == b;
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

  final selected = _PreferenceEntries();
  final elsewhere = <String, _PreferenceEntries>{};
  final routes = <String, ({String owner, String key})>{};
  final published = <String, _PreferenceEntries>{};
  var migrated = true;
  for (final entry in snapshot.entries) {
    final full = entry.key;
    if (!full.startsWith('flutter.')) continue;
    final bare = full.substring('flutter.'.length);
    // The active-profile pointer has its own file and was carried there before
    // this ran; the rest is settings.
    if (full == _legacyActiveKey) continue;

    final routed = routeLegacyKey(bare, known);
    final typed = ProfilePreferencesStore._decodeValue(
      _typeOf(entry.value),
      entry.value,
      legacyCopy: true,
    );
    if (typed == null) {
      // Migrate readable settings, but keep the source for values this build
      // cannot write in its own format.
      migrated = false;
      continue;
    }
    final destination = routed.owner == profile
        ? selected
        : (elsewhere[routed.owner] ??= {});
    destination.putIfAbsent('flutter.${routed.key}', () => typed);
    routes[full] = routed;
  }

  // All newly imported keys require a successful write before the legacy
  // source can be cleared. An unchanged snapshot needs no second write.
  if (await into._importLegacy(selected, legacy, profile, ensureFile: true)) {
    published[profile] = into._entries;
  } else {
    migrated = false;
  }
  for (final other in elsewhere.entries) {
    final path = profilePrefsPath(supportDir, other.key);
    ProfilePreferencesFile? owner;
    ProfilePreferencesStore? store;
    try {
      owner = await openOwnedFile?.call(path);
      store = await ProfilePreferencesStore.load(path, ownedFile: owner);
      if (await store._importLegacy(other.value, legacy, other.key)) {
        published[other.key] = store._entries;
      } else {
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

  try {
    // Expanding the allowlist would erase values absent from the original
    // snapshot. A key alone is insufficient: the source can have a different
    // value now, or the destination can already hold an independent value.
    final copied = <String>{
      if (snapshot.containsKey(_legacyActiveKey)) _legacyActiveKey,
    };
    for (final entry in routes.entries) {
      final route = entry.value;
      final stored = published[route.owner]?['flutter.${route.key}'];
      // A setting written directly to the profile supersedes the legacy
      // value. A copy imported on an earlier launch grants no authority to
      // discard a different value from that same source.
      if (stored != null &&
          (!stored.legacyCopy ||
              _sameLegacyValue(snapshot[entry.key], stored.value))) {
        copied.add(entry.key);
      }
    }
    if (copied.isEmpty) return;
    // The platform store has no conditional delete. Keep the final read close
    // to the clear, and leave other keys untouched when its values have changed.
    final cleanupSource = _freshLegacyReader(legacy);
    final latest = await cleanupSource.getAll();
    final migratedKeys = {
      for (final key in copied)
        if (_sameLegacyValue(snapshot[key], latest[key])) key,
    };
    if (migratedKeys.isEmpty) return;
    if (await cleanupSource.clearWithParameters(
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
