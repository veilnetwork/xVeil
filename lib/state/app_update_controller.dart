import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/update/app_update.dart';
import '../features/settings/error_report.dart' show kAppVersion;
import 'providers.dart';

/// When the last check happened, so the next one is a day later and not a
/// launch later. Device-wide rather than identity-scoped: it describes this
/// INSTALL's traffic to github.com, not anything a profile did.
const String kUpdateLastCheckPrefKey = 'xveil.update.lastCheckMs';

/// Whether to ask at all.
const String kUpdateCheckEnabledPrefKey = 'xveil.update.enabled';

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
      final prefs = await ref.read(prefsProvider.future);
      if (!_userSet) {
        state = prefs.getBool(kUpdateCheckEnabledPrefKey) ?? true;
      }
    } catch (_) {
      // No prefs (tests) — keep the default.
    }
  }

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setBool(kUpdateCheckEnabledPrefKey, value);
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
    if (!ref.read(updateCheckEnabledProvider)) return;
    final at = now ?? DateTime.now();
    try {
      final prefs = await ref.read(prefsProvider.future);
      final storedMs = prefs.getInt(kUpdateLastCheckPrefKey);
      final last = storedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(storedMs);
      if (!shouldCheckForUpdate(lastCheck: last, now: at)) return;
      // Stamped BEFORE the request, not after. A check that hangs or dies must
      // still count as "asked today", or a device that cannot reach github.com
      // asks again on every single launch — the exact traffic pattern the
      // interval exists to prevent.
      await prefs.setInt(kUpdateLastCheckPrefKey, at.millisecondsSinceEpoch);
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
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setInt(
        kUpdateLastCheckPrefKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // Best effort.
    }
    return found;
  }

  /// Put the offer away without pretending the release does not exist: the
  /// settings screen still shows it, and the next interval will find it again.
  void dismiss() => state = null;
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdate?>(
  AppUpdateController.new,
);
