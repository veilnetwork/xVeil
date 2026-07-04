import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _kFolderPanelKey = 'folder_panel_position';

/// Where the chat-folder navigation lives on the chats screen.
enum FolderPanelPosition {
  /// Collapsible drawer on the LEFT (hamburger in the app bar). Default.
  left,

  /// Collapsible drawer on the RIGHT.
  right,

  /// Always-visible horizontal chip bar under the app bar (the original UI).
  top,
}

/// Default for [folderPanelPositionProvider] and the value used when prefs
/// are unavailable (tests).
const kFolderPanelDefault = FolderPanelPosition.left;

/// Persisted placement of the folder panel. Non-sensitive (pure layout
/// preference), so plain prefs are fine — same contract as
/// [ChatPageSizeController].
class FolderPanelController extends Notifier<FolderPanelPosition> {
  bool _userSet = false;

  @override
  FolderPanelPosition build() {
    _load();
    return kFolderPanelDefault;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (_userSet) return;
      final raw = prefs.getString(_kFolderPanelKey);
      state = FolderPanelPosition.values.firstWhere(
        (p) => p.name == raw,
        orElse: () => kFolderPanelDefault,
      );
    } catch (_) {
      // No prefs (tests) — keep the default.
    }
  }

  Future<void> set(FolderPanelPosition value) async {
    _userSet = true;
    state = value;
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setString(_kFolderPanelKey, value.name);
    } catch (_) {
      // Persist best-effort.
    }
  }
}

final folderPanelPositionProvider =
    NotifierProvider<FolderPanelController, FolderPanelPosition>(
      FolderPanelController.new,
    );
