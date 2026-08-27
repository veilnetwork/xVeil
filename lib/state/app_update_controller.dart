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

/// Carry a choice made before this store existed into it, once.
///
/// The pair moved from `SharedPreferences` — which is per-profile in
/// production, however install-wide it looks — to a file beside the profile
/// directories. What that move left behind was the choice itself: nothing read
/// the old key, so an upgrade found an empty store, took the default, and
/// asked github.com on behalf of somebody who had turned checks off
/// (report16 XV-13). The comment on the constants said "kept for the
/// migration" while there was none.
///
/// Only a stored FALSE is carried over. The keys are per profile, so a `true`
/// in one says nothing about another, while an opt-out anywhere is a choice to
/// respect everywhere: the safe direction is the one that sends no packet.
///
/// The stamp is carried as the LATER of the two, so an upgrade cannot reset
/// the daily throttle and let a check out early.
///
/// Safe to run again, and it does — there is no "already migrated" marker.
/// One was written first and turned out to hold nothing: the conditions below
/// are each idempotent on their own, and a marker that guards nothing is a
/// piece of persisted state that can be wrong. Measured, by breaking it and
/// watching every test stay green.
Future<void> migrateUpdatePrefs(Ref ref) async {
  final install = await ref.read(installUpdatePrefsProvider.future);
  try {
    final legacy = await ref.read(prefsProvider.future);
    if (install.enabled == null &&
        legacy.getBool(kUpdateCheckEnabledPrefKey) == false) {
      install.enabled = false;
    }
    final legacyMs = legacy.getInt(kUpdateLastCheckPrefKey);
    if (legacyMs != null) {
      final was = install.lastCheck;
      final carried = DateTime.fromMillisecondsSinceEpoch(legacyMs);
      if (was == null || carried.isAfter(was)) install.lastCheck = carried;
    }
  } catch (_) {
    // No legacy store to read (tests, a fresh install). Nothing to carry.
  }
}

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
      await migrateUpdatePrefs(ref);
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
      // Before anything decides: an opt-out made in the old store is the
      // answer here, and this is the last moment before a request.
      await migrateUpdatePrefs(ref);
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

  /// Whether the LAST choice reached the disk.
  ///
  /// Null before anything has been chosen. `false` means the switch holds for
  /// this session and will be back where it was at the next launch — which for
  /// an opt-OUT means a request to github.com the person thought they had
  /// stopped, so it is worth saying rather than swallowing (report17
  /// XV17-M2).
  bool? get lastChoicePersisted => _persisted;
  bool? _persisted;

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;
    try {
      final prefs = await ref.read(installUpdatePrefsProvider.future);
      _persisted = prefs.setEnabled(value);
    } catch (_) {
      // No prefs at all (tests, a broken store). The switch still holds for
      // this session, and the caller can see that it did not persist.
      _persisted = false;
    }
    ref.notifyListeners();
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

  /// Which look is the current one.
  ///
  /// Two paths reach the network — the automatic one at launch and the button
  /// on the settings screen — and neither knew about the other. A slow
  /// automatic check could finish AFTER a manual one had already found a
  /// release and overwrite it with its own stale answer; the reverse order
  /// lost the find the same way. Last-write-wins, on a value that is not a
  /// clock (report15 X15-L11).
  ///
  /// Taken at the moment a look STARTS, so the newest question is the one
  /// whose answer counts, whatever order the answers come back in.
  int _generation = 0;

  /// Whether this look may still speak, and what it is allowed to say.
  ///
  /// Superseded looks are silent. A look that could not REACH the feed is
  /// silent about the offer too when there is one standing: failing to ask is
  /// not evidence that the release nobody has dismissed stopped existing. It
  /// still updates [lastReached], because "could not check" is exactly what
  /// the screen needs to show.
  void _apply(AppUpdateCheck result, int mine) {
    if (mine != _generation) return;
    _lastReached = result.reached;
    if (!result.reached && state != null) return;
    state = result.update;
  }

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
    final mine = ++_generation;
    final result = await (checker ?? AppUpdateChecker(running: kAppVersion))
        .check();
    _apply(result, mine);
  }

  /// Whether the last look actually reached the release feed.
  ///
  /// Null before anything has looked. The screen needs this to tell "up to
  /// date" apart from "could not check": the stamp is written BEFORE the
  /// request — deliberately, so a device that cannot reach github.com does not
  /// ask on every launch — so its presence says an attempt was made and
  /// nothing about how it went.
  bool? get lastReached => _lastReached;
  bool? _lastReached;

  /// Ask right now because a person pressed a button. Ignores the interval —
  /// they are looking at the screen, so the traffic is theirs to spend — but
  /// still records the stamp so the automatic one does not repeat it.
  Future<AppUpdate?> checkNow({AppUpdateChecker? checker}) async {
    final mine = ++_generation;
    final result = await (checker ?? AppUpdateChecker(running: kAppVersion))
        .check();
    _apply(result, mine);
    // Returned whatever the shared state ended up as: the caller pressed the
    // button and is owed this look's answer even if a newer one has since
    // taken the state.
    final found = result.update;
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
    // The SAME store the throttle uses. This read the per-profile one and the
    // throttle read the install-wide one, so the tile could say "not checked
    // yet" minutes after a check that the throttle counted.
    await migrateUpdatePrefs(ref);
    return (await ref.read(installUpdatePrefsProvider.future)).lastCheck;
  } catch (_) {
    return null;
  }
});

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdate?>(
  AppUpdateController.new,
);
