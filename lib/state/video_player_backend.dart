import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

/// Registers the missing Linux implementation of package:video_player.
///
/// Linux resolves libmpv from the distribution at runtime. No media bytes or
/// plaintext file paths are handed to this adapter: [VideoPlayerScreen] keeps
/// serving decrypted bytes from its tokenized RAM-only loopback server.
void initializeVideoPlayerBackend({
  @visibleForTesting bool? linux,
  @visibleForTesting VoidCallback? initializeLinux,
}) {
  if (!(linux ?? Platform.isLinux)) return;
  (initializeLinux ??
      () => VideoPlayerMediaKit.ensureInitialized(linux: true))();
}
