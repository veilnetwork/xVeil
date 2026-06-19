import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import 'providers.dart';

const _kBackgroundNodeKey = 'keep_node_background';

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
    // Apply immediately if a node is already up; otherwise it takes effect when
    // the node next boots (app_controller calls [applyIfNodeUp]).
    final nodeUp = ref.read(realStackProvider) != null ||
        ref.read(sessionProvider) != null;
    if (value && nodeUp) {
      await VeilBackground.start();
    } else if (!value) {
      await VeilBackground.stop();
    }
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setBool(_kBackgroundNodeKey, value);
    } catch (_) {
      // Persist best-effort.
    }
  }

  /// Start/stop the foreground service to match the current setting — called by
  /// app_controller after the node boots and on teardown.
  Future<void> applyIfNodeUp({required bool nodeUp}) async {
    if (state && nodeUp) {
      await VeilBackground.start();
    } else {
      await VeilBackground.stop();
    }
  }
}

final backgroundNodeProvider =
    NotifierProvider<BackgroundNodeController, bool>(
        BackgroundNodeController.new);
