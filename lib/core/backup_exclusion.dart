import 'package:flutter/services.dart';

/// Whether the app's data directory is actually kept out of the device backup.
///
/// On iOS the encrypted container, the node's runtime directory and every
/// per-profile preference file live under Application Support, and iOS copies
/// that into iCloud and encrypted Finder/iTunes backups by DEFAULT. The runner
/// sets `isExcludedFromBackup` on the directory at launch to stop it.
///
/// Setting it is not the same as it being set. `setResourceValues` returning
/// without throwing means the call was accepted; the runner now reads the flag
/// back (after dropping the cached value, or it would just re-read its own
/// assertion) and remembers what it found. A missing directory used to be a
/// silent `return`.
///
/// This is the read side. It REPORTS and nothing more — Settings → Privacy
/// shows a warning. Refusing to unlock over it, as the audit suggested, would
/// take a working app away from someone over a condition they cannot fix from
/// inside it, and the container is still encrypted either way; what is lost is
/// deniability of its EXISTENCE and the chance to attack it offline.
class BackupExclusion {
  const BackupExclusion({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'xveil/backup_exclusion';

  final MethodChannel _channel;

  /// Null when the data directory is excluded — or when this platform is not
  /// one where the question means anything.
  ///
  /// A non-null string is the reason it is not excluded, straight from the
  /// runner. Deliberately not a bool: "not excluded" and "why" arrive together
  /// or the warning is unactionable, and there is no third state worth adding
  /// (a platform that cannot answer is not at risk from THIS, since Android
  /// seals the same data with `allowBackup=false` in the manifest and the
  /// desktops have no OS backup service in the loop).
  Future<String?> problem() async {
    try {
      return await _channel.invokeMethod<String>('problem');
    } on MissingPluginException {
      // Android, Windows, Linux, macOS and every test host: no handler, and
      // nothing to warn about.
      return null;
    } on PlatformException {
      // The runner is there but the call failed. Not evidence that the data is
      // exposed, and inventing a warning out of it would train people to
      // ignore the real one.
      return null;
    }
  }
}
