import 'dart:io';

import 'package:window_manager/window_manager.dart';

import '../core/log.dart';

bool _showInFlight = false;
final _showClock = Stopwatch()..start();
Duration? _lastShowAt;

/// Tray and notification activation share one guard: overlapping native
/// show/focus calls previously crashed macOS on a tray double-click.
Future<void> showDesktopWindow() async {
  if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return;
  final now = _showClock.elapsed;
  final last = _lastShowAt;
  if (_showInFlight ||
      (last != null && now - last < const Duration(milliseconds: 400))) {
    return;
  }
  _showInFlight = true;
  _lastShowAt = now;
  try {
    // window_manager.show() also restores a minimized window.
    await windowManager.show();
    await windowManager.focus();
  } catch (_) {
    devLog(() => 'xVeil[window]: show/focus failed');
  } finally {
    _showInFlight = false;
  }
}
