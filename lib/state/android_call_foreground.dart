import 'package:flutter/foundation.dart';

import '../core/android_microphone_lifetime.dart';

export '../core/android_microphone_lifetime.dart';

/// Microphone-typed Android foreground grant. Actual capture belongs to the
/// media engine. Controllers must bind a profile lifetime before any await.
class AndroidCallForegroundService {
  static AndroidMicrophoneLifetime bind() =>
      AndroidMicrophoneLifetime.current();
  static bool get isActive => bind().isActive;

  @visibleForTesting
  static set debugInvokeOverride(Future<bool?> Function(bool active)? value) {
    // The forwarding seam is itself test-only.
    // ignore: invalid_use_of_visible_for_testing_member
    AndroidMicrophoneLifetime.debugInvokeOverride = value;
  }

  @visibleForTesting
  static void debugReset() {
    // ignore: invalid_use_of_visible_for_testing_member
    AndroidMicrophoneLifetime.debugReset();
  }

  static Future<void> setActive(bool active) => bind().setActive(active);
  static Future<void> activateWhenMicrophoneGranted(
    Future<bool> permission, {
    required bool Function() isCurrent,
  }) => bind().activateWhenMicrophoneGranted(permission, isCurrent: isCurrent);
}
