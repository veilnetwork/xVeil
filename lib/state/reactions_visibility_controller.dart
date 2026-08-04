import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_settings_sync.dart';
import 'identity_scoped_prefs.dart';
import 'providers.dart';

/// PER PROFILE (audit XV-15) — same class as the language: a display choice one
/// profile made should not describe another, and a wipe should take it.
String get _kShowReactionsKey => identityScopedPrefKey(kSyncShowReactions);

/// Whether message reactions are rendered at all — the chips under bubbles and
/// the quick-react bar in the long-press menu, in BOTH 1:1 chats and groups.
///
/// A local display preference: hiding reactions neither deletes them nor stops
/// their sync, so flipping the switch back restores everything. Non-sensitive
/// (a boolean carries no content or peer identity), so plain prefs are fine —
/// same reasoning as [chatPageSizeProvider].
class ShowReactionsController extends Notifier<bool> {
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
        state = prefs.getBool(_kShowReactionsKey) ?? true;
      }
    } catch (_) {
      // No prefs (tests) — keep the default.
    }
  }

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;
    // Device sync: an allowlisted preference — mirror the local set to my
    // other devices (no-op while an incoming synced value is being applied).
    ref
        .read(deviceSettingsSyncHubProvider)
        .notifyLocalSet(kSyncShowReactions, value ? '1' : '0');
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setBool(_kShowReactionsKey, value);
    } catch (_) {
      // Persist best-effort.
    }
  }
}

final showReactionsProvider = NotifierProvider<ShowReactionsController, bool>(
  ShowReactionsController.new,
);
