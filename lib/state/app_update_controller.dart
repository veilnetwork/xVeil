import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path_provider/path_provider.dart';

import '../data/update/app_update.dart';
import '../data/update/install_prefs.dart';
import '../features/settings/error_report.dart' show kAppVersion;
import 'providers.dart';

/// When the last check happened, so the next one is a day later and not a
/// launch later. Device-wide rather than identity-scoped: it describes this
/// INSTALL's traffic to github.com, not anything a profile did.
///
/// Kept in [InstallUpdatePrefs] and NOT in `SharedPreferences`, which is
/// per-profile in production however install-wide it looks: the platform
/// backend is swapped for a file inside the active profile's directory. The
/// keys stay here for the migration and for tests.
const String kUpdateLastCheckPrefKey = 'xveil.update.lastCheckMs';

/// Whether to ask at all.
const String kUpdateCheckEnabledPrefKey = 'xveil.update.enabled';

/// Where the install-wide pair lives. Overridden in tests.
final installUpdatePrefsProvider = FutureProvider<InstallUpdatePrefs>((
  ref,
) async {
  final dir = await getApplicationSupportDirectory();
  return InstallUpdatePrefs(InstallUpdatePrefs.pathIn(dir.path));
});

/// Whether the app looks for a newer release. On by default; the switch exists
/// because the request is an outbound connection to github.com that says this
/// device runs xVeil, and in this app that is a choice worth leaving open.
class UpdateCheckEnabledController extends Notifier<bool> {
  /// The stored value arrives asynchronously, and a person can flip the switch
  /// before it does. Without this the load lands afterwards and puts the old
  /// answer back — a switch that springs to its previous position a moment
  /// after being moved.
  bool _userSet = false;

  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(installUpdatePrefsProvider.future);
      if (!_userSet) state = prefs.enabled ?? true;
    } catch (_) {
      // No store to read (tests) — keep the default.
    }
  }

  /// The answer to act on before touching the network.
  ///
  /// [state] starts at the default and the stored value arrives later, so a
  /// launch that asks the plain provider sees "on" for a person who turned it
  /// off — and the request goes out before their choice has finished loading.
  /// A setting whose whole purpose is to stop an outbound connection cannot be
  /// read optimistically.
  ///
  /// A choice made in THIS session wins over the stored one, which may still
  /// be being written.
  Future<bool> resolved() async {
    if (_userSet) return state;
    try {
      final prefs = await ref.read(installUpdatePrefsProvider.future);
      final stored = prefs.enabled;
      if (!_userSet && stored != null) state = stored;
      return _userSet ? state : (stored ?? true);
    } catch (_) {
      // No prefs to consult (tests, a broken store). The default stands, and
      // it is the one the switch shows.
      return state;
    }
  }

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;
    try {
      (await ref.read(installUpdatePrefsProvider.future)).enabled = value;
    } catch (_) {
      // Persist best-effort: the switch still holds for this session.
    }
  }
}

final updateCheckEnabledProvider =
    NotifierProvider<UpdateCheckEnabledController, bool>(
      UpdateCheckEnabledController.new,
    );

/// The newer release to offer, or null while there is nothing to offer.
///
/// Holds no timer: [checkIfDue] is called when the app becomes usable, and the
/// interval is decided from the stored stamp. A background timer would ask
/// while the app is not even on screen, which is more traffic to github.com
/// for no more information.
class AppUpdateController extends Notifier<AppUpdate?> {
  @override
  AppUpdate? build() => null;

  /// Ask if the interval has elapsed. Silent about everything else: a check
  /// nobody requested must not interrupt a launch, so a refusal, a network
  /// failure and "nothing new" all look the same from here.
  ///
  /// [now] and [checker] are seams for tests; production passes neither.
  Future<void> checkIfDue({DateTime? now, AppUpdateChecker? checker}) async {
    // Resolved, not read: the stored opt-out arrives asynchronously, and the
    // plain provider answers with the default until it does.
    if (!await ref.read(updateCheckEnabledProvider.notifier).resolved()) return;
    final at = now ?? DateTime.now();
    try {
      final prefs = await ref.read(installUpdatePrefsProvider.future);
      final last = prefs.lastCheck;
      if (!shouldCheckForUpdate(lastCheck: last, now: at)) return;
      // Stamped BEFORE the request, not after. A check that hangs or dies must
      // still count as "asked today", or a device that cannot reach github.com
      // asks again on every single launch — the exact traffic pattern the
      // interval exists to prevent.
      prefs.lastCheck = at;
    } catch (_) {
      // No prefs: check once for this session rather than not at all.
    }
    state = await (checker ?? AppUpdateChecker(running: kAppVersion)).check();
  }

  /// Ask right now because a person pressed a button. Ignores the interval —
  /// they are looking at the screen, so the traffic is theirs to spend — but
  /// still records the stamp so the automatic one does not repeat it.
  Future<AppUpdate?> checkNow({AppUpdateChecker? checker}) async {
    final found = await (checker ?? AppUpdateChecker(running: kAppVersion))
        .check();
    state = found;
    try {
      (await ref.read(installUpdatePrefsProvider.future)).lastCheck =
          DateTime.now();
    } catch (_) {
      // Best effort.
    }
    return found;
  }

  /// Put the offer away without pretending the release does not exist: the
  /// settings screen still shows it, and the next interval will find it again.
  void dismiss() => state = null;
}

/// When anything last looked, or null when nothing ever has.
///
/// The tile needs this to tell "there is nothing newer" apart from "nobody has
/// asked". Reading the stamp rather than a per-widget flag is what makes the
/// answer true after an automatic check as well: the launch check leaves no
/// trace in the widget, and the tile said "not checked yet" minutes after one
/// had run.
final updateLastCheckProvider = FutureProvider<DateTime?>((ref) async {
  // Rebuilds when the offer changes, which is the moment a check finished.
  ref.watch(appUpdateProvider);
  try {
    final prefs = await ref.read(prefsProvider.future);
    final ms = prefs.getInt(kUpdateLastCheckPrefKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  } catch (_) {
    return null;
  }
});

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdate?>(
  AppUpdateController.new,
);
