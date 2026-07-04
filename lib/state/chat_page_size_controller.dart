import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _kChatPageSizeKey = 'chat_page_size';

/// Default for [chatPageSizeProvider] and the value used when prefs are
/// unavailable (tests).
const int kChatPageSizeDefault = 100;

/// Preset choices offered by the settings picker.
const List<int> kChatPageSizeChoices = [50, 100, 200, 500, 1000];

/// How many newest messages a chat loads initially — and the step the
/// "load earlier" action grows the visible window by. Persisted; default 100.
///
/// Non-sensitive (a render-window size carries no content or peer identity),
/// so plain prefs are fine — unlike mute/pin lists, which belong in the
/// deniable store.
class ChatPageSizeController extends Notifier<int> {
  bool _userSet = false;

  @override
  int build() {
    _load();
    return kChatPageSizeDefault;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (!_userSet) {
        state = prefs.getInt(_kChatPageSizeKey) ?? kChatPageSizeDefault;
      }
    } catch (_) {
      // No prefs (tests) — keep the default.
    }
  }

  Future<void> set(int value) async {
    if (value <= 0) return;
    _userSet = true;
    state = value;
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setInt(_kChatPageSizeKey, value);
    } catch (_) {
      // Persist best-effort.
    }
  }
}

final chatPageSizeProvider =
    NotifierProvider<ChatPageSizeController, int>(ChatPageSizeController.new);
