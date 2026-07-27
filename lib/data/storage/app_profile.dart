import 'dart:io' show Platform;

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
  }) {
    for (final candidate in [
      _fromArgs(args),
      (environment ?? Platform.environment)[envVar],
      remembered,
    ]) {
      final name = candidate?.trim().toLowerCase();
      if (name != null && name.isNotEmpty && isValidName(name)) return name;
    }
    return defaultName;
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
