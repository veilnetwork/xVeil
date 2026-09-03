import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _kCloseToTrayKey = 'close_to_tray';

/// Whether closing the desktop window HIDES to the system tray (keeping the node
/// — and therefore notifications + offline delivery — running) instead of
/// quitting. Persisted; default **true** on desktop (the point of the feature).
///
/// Non-sensitive (a window-behavior preference), so plain prefs are fine.
/// No-op on mobile (there is no desktop window to intercept).
class CloseToTrayController extends Notifier<bool> {
  bool _userSet = false;
  Future<void>? _loading;

  @override
  bool build() {
    _loading = _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (!_userSet) state = prefs.getBool(_kCloseToTrayKey) ?? true;
    } catch (_) {
      // No prefs (tests) — default on.
    }
  }

  /// The PERSISTED answer, which [state] is not until the load lands.
  ///
  /// `build()` must return synchronously, so the first read of this provider
  /// is always the optimistic default. Riverpod builds lazily, and the only
  /// read that decides anything — the one in `onWindowClose` — is on a cold
  /// start also the FIRST read: nothing else touches this provider except the
  /// settings screen. So a user who turned close-to-tray off had it honoured
  /// until they restarted, and every launch after that hid the window again
  /// unless they happened to reopen that screen. Measured on the Windows
  /// stand: the preference file said false and the window went to the tray.
  ///
  /// The close path is already async, so it can wait for the truth.
  Future<bool> resolved() async {
    await _loading;
    return state;
  }

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setBool(_kCloseToTrayKey, value);
    } catch (_) {
      // Persist best-effort.
    }
  }
}

final closeToTrayProvider = NotifierProvider<CloseToTrayController, bool>(
  CloseToTrayController.new,
);
