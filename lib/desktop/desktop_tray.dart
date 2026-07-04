import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/log.dart';
import '../l10n/app_localizations.dart';
import '../state/close_to_tray_controller.dart';

/// True on the three desktop platforms that have a window + a system tray.
bool get isDesktopTrayPlatform =>
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// One-time desktop window init, called from `main` BEFORE `runApp` (no-op off
/// desktop). Arms window_manager so [DesktopTrayHost] can intercept the close
/// button and hide to tray instead of quitting.
Future<void> initDesktopWindow() async {
  if (!isDesktopTrayPlatform) return;
  await windowManager.ensureInitialized();
  // Intercept the close button; the host's onWindowClose decides hide-vs-quit
  // based on the persisted setting.
  await windowManager.setPreventClose(true);
}

/// Wraps the app on desktop to own the tray icon + menu and the
/// close-to-tray behavior. Transparent passthrough on mobile.
///
/// Behavior:
/// * Close button → hide to tray (when [closeToTrayProvider] is on) so the
///   embedded node keeps running and notifications keep arriving; else quit.
/// * Tray icon click → show + focus the window.
/// * Tray menu → Show / Hide / Quit.
class DesktopTrayHost extends ConsumerStatefulWidget {
  const DesktopTrayHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<DesktopTrayHost> createState() => _DesktopTrayHostState();
}

class _DesktopTrayHostState extends ConsumerState<DesktopTrayHost>
    with WindowListener, TrayListener {
  static const _kShow = 'show';
  static const _kHide = 'hide';
  static const _kQuit = 'quit';

  bool get _enabled => isDesktopTrayPlatform;

  @override
  void initState() {
    super.initState();
    if (!_enabled) return;
    windowManager.addListener(this);
    trayManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initTray());
  }

  Future<void> _initTray() async {
    if (!mounted) return;
    // This host sits ABOVE MaterialApp (no Localizations in scope), so the
    // menu labels come from the generated lookup keyed by the OS locale —
    // AppL10n.of(context) here threw and killed the whole tray init (the
    // "closed to nothing, no icon" bug).
    final l = lookupAppL10n(PlatformDispatcher.instance.locale);
    try {
      // Re-arm close interception from a live frame too: the pre-runApp call
      // in initDesktopWindow is the designed path, but re-asserting here makes
      // close-to-tray survive any init-order regression.
      await windowManager.setPreventClose(true);
      // PNG works for macOS/Linux; Windows tray prefers an .ico but falls back
      // acceptably — a device pass can point Windows at app_icon.ico if needed.
      await trayManager.setIcon('assets/icon/app_icon.png');
      await trayManager.setContextMenu(
        Menu(items: [
          MenuItem(key: _kShow, label: l.trayShow),
          MenuItem(key: _kHide, label: l.trayHide),
          MenuItem.separator(),
          MenuItem(key: _kQuit, label: l.trayQuit),
        ]),
      );
      final armed = await windowManager.isPreventClose();
      devLog(() => 'xVeil[tray]: icon+menu installed (preventClose=$armed)');
    } catch (e) {
      // A tray init failure (no tray available, headless CI) must never crash
      // the app — the window just behaves normally. LOUD in the log: a silent
      // catch here previously hid the l10n crash entirely.
      devLog(() => 'xVeil[tray]: init FAILED: $e');
    }
  }

  @override
  void dispose() {
    if (_enabled) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // ── WindowListener ────────────────────────────────────────────────────────
  @override
  void onWindowClose() async {
    // preventClose is armed (initDesktopWindow), so the window won't close on
    // its own — we decide. Close-to-tray on → hide; off → really quit.
    final closeToTray = ref.read(closeToTrayProvider);
    devLog(() => 'xVeil[tray]: window close intercepted, '
        'closeToTray=$closeToTray');
    if (closeToTray) {
      await windowManager.hide();
    } else {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  // ── TrayListener ──────────────────────────────────────────────────────────
  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case _kShow:
        await _show();
      case _kHide:
        await windowManager.hide();
      case _kQuit:
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
