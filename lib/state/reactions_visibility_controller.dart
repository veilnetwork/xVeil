import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _kShowReactionsKey = 'show_reactions';

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
