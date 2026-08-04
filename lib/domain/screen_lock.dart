/// How long the app may sit in the background before the SCREEN locks.
///
/// The screen, deliberately — not the volume. Locking the volume would stop
/// delivery: the node comes down with it, messages stop arriving and the
/// notification the user is waiting for never appears. This locks what is
/// visible and leaves everything behind it running, so someone who picks the
/// phone up sees a password prompt while the conversation carries on.
///
/// It is honest about what that buys. The container is still open, so its keys
/// are still in this process's memory; a device seized in this state is not
/// protected by this setting. What it defends against is the ordinary case —
/// the phone out of your hands for a minute.
enum ScreenLockTimeout {
  /// Never lock on its own. The default: it is the behaviour every existing
  /// install already has, and a lock nobody asked for looks like a bug.
  off,

  /// The moment the app stops being frontmost.
  immediately,

  oneMinute,

  fiveMinutes,

  fifteenMinutes,
}

extension ScreenLockTimeoutDuration on ScreenLockTimeout {
  /// How long away is tolerated. Null for [off], which never locks at all —
  /// distinct from [immediately], which is `Duration.zero`.
  Duration? get after => switch (this) {
    ScreenLockTimeout.off => null,
    ScreenLockTimeout.immediately => Duration.zero,
    ScreenLockTimeout.oneMinute => const Duration(minutes: 1),
    ScreenLockTimeout.fiveMinutes => const Duration(minutes: 5),
    ScreenLockTimeout.fifteenMinutes => const Duration(minutes: 15),
  };
}

/// The persisted setting key. Lives INSIDE the container (like the P2P and
/// signature policies) rather than in `shared_preferences`: it is only ever
/// consulted while the container is open, so there is no reason to leave a
/// record of it where a forensic tool reads it without a password.
const kScreenLockTimeoutSettingKey = 'screen_lock_timeout';

ScreenLockTimeout screenLockTimeoutFromName(String? name) =>
    ScreenLockTimeout.values
        .where((value) => value.name == name)
        .firstOrNull ??
    ScreenLockTimeout.off;

/// Whether being away for [awayFor] is long enough to lock.
///
/// Pure, and separate from the clock on purpose: "after fifteen minutes" is
/// the kind of rule that is easy to write as `>` and ship as "never locks at
/// exactly the timeout".
bool screenLockDue({
  required ScreenLockTimeout timeout,
  required Duration awayFor,
}) {
  final after = timeout.after;
  if (after == null) return false;
  return awayFor >= after;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
