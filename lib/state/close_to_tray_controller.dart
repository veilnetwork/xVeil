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

  @override
  bool build() {
    _load();
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

final closeToTrayProvider =
    NotifierProvider<CloseToTrayController, bool>(CloseToTrayController.new);
