import 'dart:io';

import 'async_kv_log_store.dart';
import 'app_profile.dart';
import 'legacy_profile_preferences.dart';
import 'profile_prefs_store.dart';

typedef ProfilePreferencesBootstrap = ({
  String? profile,
  String? supportDirectory,
  bool erasurePending,
  LegacyProfilePreferences? legacyPreferences,
});

/// Resolve the launch profile without modifying it, then acquire its actual
/// native file owner before migration. Pending erasure is a separate startup
/// route; other managed admission failures propagate instead of using fakes.
Future<ProfilePreferencesBootstrap> bootstrapProfilePreferences({
  required Future<String> Function() supportDir,
  required List<String> args,
  Map<String, String>? environment,
  bool managedStorage = const bool.fromEnvironment('XVEIL_MANAGED_STORAGE'),
  void Function(Object error, StackTrace stack)? onError,
}) async {
  final source = environment ?? Platform.environment;
  // Read through the source's lookup policy before snapshotting: Windows
  // environment maps may compare variable names without regard to case.
  final env = <String, String>{
    for (final key in [AppProfiles.envVar, 'XVEIL_STORE_PATH'])
      if (source[key] case final String value) key: value,
  };
  String? selectedSupport;
  LegacyProfilePreferences? legacySource;
  try {
    final profile = await installProfilePreferencesOrFallback(
      supportDir: () async => selectedSupport = await supportDir(),
      args: args,
      environment: env,
      openOwnedFile: managedStorage ? ManagedProfilePreferencesFile.open : null,
      validateSelectedFile: managedStorage
          ? (path) => validateManagedPreferencesContainer(
              path,
              env['XVEIL_STORE_PATH'],
            )
          : null,
      onError: onError,
      onResolvedLegacySource: (source) => legacySource = source,
    );
    return (
      profile: profile,
      supportDirectory: selectedSupport,
      erasurePending: false,
      legacyPreferences: legacySource,
    );
  } on ProfilePreferencesErasurePending {
    return (
      profile: null,
      supportDirectory: selectedSupport,
      erasurePending: true,
      legacyPreferences: legacySource,
    );
  }
}
