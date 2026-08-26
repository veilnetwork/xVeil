import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import 'providers.dart';

const _kBackgroundNodeKey = 'keep_node_background';

/// The two platform calls this controller makes, behind a seam.
///
/// A seam rather than a direct static call because the interesting failure is
/// the one where the platform REFUSES: from Android 12 `startForeground()`
/// throws for an app the system does not consider eligible. Off-Android
/// `VeilBackground` is a no-op that cannot throw, so without this the "the
/// choice survives a refusal" test would pass on code that loses it — the same
/// shape as `vpnBackendProvider` and `vpnTransportPreflightProvider`.
class BackgroundServiceActions {
  const BackgroundServiceActions({required this.start, required this.stop});
  final Future<void> Function() start;
  final Future<void> Function() stop;
}

final backgroundServiceProvider = Provider<BackgroundServiceActions>(
  (_) => BackgroundServiceActions(
    start: VeilBackground.start,
    stop: VeilBackground.stop,
  ),
);

/// Whether the node should keep running when the app is backgrounded (Android),
/// via veil_flutter's foreground service. Persisted; default **false**.
///
/// OFF (default) is the deniability-safe choice: a foreground service REQUIRES a
/// persistent, visible notification, which advertises that the app is running —
/// undesirable under observation. ON trades that for availability: the embedded
/// node (and therefore the SOCKS5 proxy AND offline-message delivery) keeps
/// working after you switch away from the app, instead of the OS suspending the
/// process. No-op on non-Android platforms (desktop already keeps running; iOS
/// has no equivalent always-on mechanism here).
class BackgroundNodeController extends Notifier<bool> {
  bool _userSet = false;

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (!_userSet) state = prefs.getBool(_kBackgroundNodeKey) ?? false;
    } catch (_) {
      // No prefs (tests) — safe default off.
    }
  }

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;

    // PERSIST BEFORE APPLYING, and never behind an unguarded await.
    //
    // The write used to sit AFTER `await VeilBackground.start()`, outside its
    // own protection: a platform call that threw — Android 12+ refusing
    // `startForeground()` for an app it deems ineligible is the ordinary case —
    // skipped the write entirely. The switch then showed ON from memory and
    // reverted to OFF the next time this notifier was rebuilt, silently, with
    // the node no longer surviving the screen going off. Whichever way the
    // platform answers, the person's choice is the thing to keep: a service
    // that would not start now is retried on the next node boot by
    // [applyIfNodeUp], and the Network screen already warns when the battery
    // exemption is missing.
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setBool(_kBackgroundNodeKey, value);
    } catch (_) {
      // Persist best-effort.
    }

    // Apply immediately if a node is already up; otherwise it takes effect when
    // the node next boots (app_controller calls [applyIfNodeUp]).
    final nodeUp =
        ref.read(realStackProvider) != null ||
        ref.read(sessionProvider) != null;
    final service = ref.read(backgroundServiceProvider);
    if (value && nodeUp) {
      await service.start();
    } else if (!value) {
      await service.stop();
    }
  }

  /// Start/stop the foreground service to match the current setting — called by
  /// app_controller after the node boots and on teardown.
  Future<void> applyIfNodeUp({required bool nodeUp}) async {
    final service = ref.read(backgroundServiceProvider);
    if (state && nodeUp) {
      await service.start();
    } else {
      await service.stop();
    }
  }
}

final backgroundNodeProvider = NotifierProvider<BackgroundNodeController, bool>(
  BackgroundNodeController.new,
);
