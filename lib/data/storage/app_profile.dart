import 'dart:io' show FileSystemEntity, FileSystemEntityType, Platform;

import '../../core/log.dart';

/// WHERE the profile for this launch came from.
///
/// The name alone is not enough to act on. Two of these sources are one-shot
/// instructions for this run only, one is a stored choice that already lives
/// where it belongs, one is a stored choice in a place that is about to be
/// erased, and the last is no choice at all — and the migration in
/// `installProfilePreferences` has to treat all five differently. Returning
/// only the name is what let a remembered non-default profile be forgotten on
/// the second launch after the upgrade (audit X-01).
enum ProfileSource {
  /// `--profile name` / `--profile=name` on the command line.
  argument,

  /// The `XVEIL_PROFILE` environment variable.
  environment,

  /// The `xveil.profile` file — the switcher's own record.
  newPointer,

  /// The `profile.active.v1` preference in the platform's system store: the
  /// pre-migration home of the same choice, and the only source that has to be
  /// CARRIED somewhere before that store is emptied.
  legacyPointer,

  /// Nothing said anything; production.
  fallbackDefault,
}

/// A profile name together with [ProfileSource].
class ResolvedProfile {
  const ResolvedProfile(this.name, this.source);

  final String name;
  final ProfileSource source;

  @override
  String toString() => 'ResolvedProfile($name from ${source.name})';
}

/// Which on-disk profile the app runs against — the equivalent of a browser's
/// `--profile`, so a debug build and the production build can live side by side
/// on one machine instead of sharing (and corrupting) one container.
///
/// A profile is ONLY a directory choice. It is not a security boundary and it
/// is not an identity: each profile holds its own deniable container, so it has
/// its own password, its own spaces and its own node state. Nothing is shared
/// between profiles except the app binary.
class AppProfiles {
  const AppProfiles._();

  /// The profile an install runs on unless told otherwise. Production.
  static const defaultName = 'default';

  /// Preference keys. These live OUTSIDE the encrypted container by necessity:
  /// the choice has to be readable before there is anything to unlock.
  static const activePref = 'profile.active.v1';
  static const revealedPref = 'profile.switcherRevealed.v1';

  /// Environment override, honoured on every platform — including the ones
  /// where a flag cannot reach the Dart entrypoint at all (a launcher icon, an
  /// Android or iOS install). Desktop forwards argv: Linux and Windows for
  /// free, macOS because MainFlutterWindow hands it to the Dart project.
  static const envVar = 'XVEIL_PROFILE';

  /// Conservative on purpose: the name becomes a path segment, so anything
  /// that could escape the profiles directory, collide case-insensitively on
  /// macOS/Windows, or confuse a shell is refused rather than sanitised.
  /// Sanitising would silently map two different names onto one container.
  static final _valid = RegExp(r'^[a-z0-9][a-z0-9._-]{0,31}$');

  static bool isValidName(String name) =>
      _valid.hasMatch(name) && !name.contains('..');

  /// Where a profile's deniable container lives.
  ///
  /// The default profile keeps the HISTORICAL path untouched. That is the whole
  /// migration story: an existing install upgrades in place and never has to
  /// move a multi-gigabyte container, and a user who never opens the switcher
  /// cannot tell this feature exists.
  static String storePath(String supportDir, String profile) =>
      profile == defaultName
      ? '$supportDir/xveil.store'
      : '$supportDir/profiles/$profile/xveil.store';

  /// The directory holding a profile's container, used to place the blob tier
  /// and anything else that must follow the container.
  static String directory(String supportDir, String profile) =>
      profile == defaultName ? supportDir : '$supportDir/profiles/$profile';

  /// Scope a preference key to [profile].
  ///
  /// Shared preferences are per-APP, so a flag that describes ONE installation
  /// has to carry the profile or a second profile inherits the first's answer.
  /// That is not hypothetical: the onboarding flag was global, so a brand-new
  /// profile started at the lock screen with no container to unlock and could
  /// never be opened at all.
  ///
  /// The default profile keeps the bare key, so an existing install is never
  /// sent back through first-launch setup.
  static String scopedPrefKey(String key, String profile) =>
      profile == defaultName ? key : '$key.$profile';

  /// Resolve the profile for this launch, most explicit source first:
  /// an argument, then the environment, then what the user last chose, then
  /// production.
  ///
  /// An unusable name is SKIPPED rather than fatal, and the next source is
  /// consulted. A typo in a launcher script must not leave someone unable to
  /// start the app — the worst case is that they land on the default profile,
  /// which is exactly where they were before.
  static String resolve({
    List<String> args = const [],
    Map<String, String>? environment,
    String? remembered,
  }) => resolveWithSource(
    args: args,
    environment: environment,
    pointer: remembered,
  ).name;

  /// [resolve], but it also says WHICH source answered.
  ///
  /// The two pointers are separate parameters rather than one `remembered`
  /// because the caller has to be able to tell them apart: the legacy one sits
  /// in a store the migration is about to empty, so it must be carried into
  /// [ProfileSource.newPointer]'s file first or the choice is lost on the NEXT
  /// launch — the launch after the one that migrated (audit X-01). An argument
  /// or an environment variable is an instruction for this run and must never
  /// become a stored choice.
  static ResolvedProfile resolveWithSource({
    List<String> args = const [],
    Map<String, String>? environment,
    String? pointer,
    String? legacyPointer,
  }) {
    final candidates = <(String?, ProfileSource)>[
      (_fromArgs(args), ProfileSource.argument),
      (
        (environment ?? Platform.environment)[envVar],
        ProfileSource.environment,
      ),
      (pointer, ProfileSource.newPointer),
      (legacyPointer, ProfileSource.legacyPointer),
    ];
    for (final (candidate, source) in candidates) {
      final name = candidate?.trim().toLowerCase();
      if (name != null && name.isNotEmpty && isValidName(name)) {
        return ResolvedProfile(name, source);
      }
    }
    return const ResolvedProfile(defaultName, ProfileSource.fallbackDefault);
  }

  /// The node's listener port for [profile], given the platform's [base].
  ///
  /// A second profile exists precisely so a second instance can run beside the
  /// first, and two nodes cannot share one UDP port — without this the second
  /// launch fails to bind and reports itself as a network problem. The default
  /// profile keeps the platform port exactly as before; every other profile
  /// gets a stable offset derived from its name, so the same profile always
  /// lands on the same port and a firewall rule keeps working.
  ///
  /// An explicit `XVEIL_LISTEN_PORT` still wins — this is only the default.
  static int listenPort(String profile, {required int base}) {
    if (profile == defaultName) return base;
    var hash = 0;
    for (final unit in profile.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return base + 1 + hash % 99;
  }

  /// Accepts both spellings a person may reasonably type: `--profile=name`
  /// and `--profile name`.
  static String? _fromArgs(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('--profile=')) {
        return arg.substring('--profile='.length);
      }
      if (arg == '--profile' && i + 1 < args.length) return args[i + 1];
    }
    return null;
  }
}

/// The profile this launch resolved to, for anything that has to report or
/// branch on it (the switcher UI, the node's listener port, and every file that
/// belongs to one profile rather than to the install).
///
/// Set once during bootstrap, before any provider reads it. It lives HERE
/// rather than in `main.dart` — which re-exports it, so every existing importer
/// is unaffected — because [activeProfileDir] needs it and the data layer must
/// not import the entrypoint.
String activeProfile = AppProfiles.defaultName;

/// Where THIS launch's profile keeps a file that belongs to one profile and not
/// to the install: the container, the blob tier beside it — and the speech and
/// translation models, which used to sit in [supportDir] itself.
///
/// The models were resolved from the bare support directory, so a second
/// profile read the FIRST profile's models and, on a wipe, deleted them. That
/// is one identity destroying another's data, and — because a translation pair
/// is a directory named `ru-en` — one identity reading the list of languages
/// the other reads.
///
/// ## Migration: nothing moves, nothing is adopted, nothing is deleted
///
/// For the default profile this returns [supportDir] unchanged, exactly as
/// [AppProfiles.storePath] keeps the historical container path. So an existing
/// install keeps every model it has already downloaded, in place, with no copy
/// and no move — the case that covers everybody who has never opened the
/// switcher.
///
/// A NON-default profile does not adopt what it finds in [supportDir]. It never
/// had a model of its own to lose; what it had was the default profile's, and
/// inheriting that is the leak itself — a throwaway profile would start out
/// holding the list of languages the real one reads. It re-downloads (or takes
/// a bundle import), and the older shared copy is LEFT WHERE IT IS.
///
/// [leftBehind] names the entries the caller owns in the pre-profile location,
/// so that choice is stated in the log instead of happening silently.
String activeProfileDir(
  String supportDir, {
  List<String> leftBehind = const [],
}) {
  final dir = AppProfiles.directory(supportDir, activeProfile);
  if (dir != supportDir) _noteLeftBehind(supportDir, dir, leftBehind);
  return dir;
}

/// Which (directory, entries) pairs have already been reported this process.
///
/// The dedup key is set OUTSIDE the log gate and the filesystem probe INSIDE
/// it: this runs on every model-path resolution, and a `stat` per resolution
/// that a release build cannot even print is a cost paid for nothing.
final Set<String> _noted = <String>{};

void _noteLeftBehind(String supportDir, String dir, List<String> names) {
  if (names.isEmpty || !_noted.add('$dir ${names.join(",")}')) return;
  devLog(() {
    final present = [
      for (final name in names)
        if (FileSystemEntity.typeSync('$supportDir/$name') !=
            FileSystemEntityType.notFound)
          name,
    ];
    if (present.isEmpty) {
      return 'xVeil[profile]: "$activeProfile" keeps its models in $dir; '
          'nothing of ${names.join(", ")} is in the shared $supportDir';
    }
    return 'xVeil[profile]: "$activeProfile" keeps its models in $dir. '
        'LEFT WHERE THEY ARE — not adopted, not deleted: '
        '${present.join(", ")} under $supportDir belong to the '
        '"${AppProfiles.defaultName}" profile. Download or import again to '
        'have them here.';
  });
}

/// Forget what [activeProfileDir] has already reported.
///
/// Only for tests: the note is once-per-process by design, and a test that
/// asserts on it must be able to ask for it again.
void debugResetProfileDirNotes() => _noted.clear();
