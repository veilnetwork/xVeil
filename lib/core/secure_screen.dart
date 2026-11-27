import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeping what is on screen out of screenshots, recordings and the task
/// switcher.
///
/// The app already refuses to let its data leave the device by any file route:
/// `allowBackup="false"`, data-extraction rules, an encrypted container. The
/// screen was outside that perimeter — `FLAG_SECURE` and its equivalents
/// appeared nowhere in the app (audit X-11) — and the screen is where the
/// recovery phrase is shown.
///
/// PER ROUTE, not globally, and that is not a compromise: `FLAG_SECURE` blacks
/// out the window inside the app's OWN `MediaProjection` too, so setting it
/// once at startup would silently break the screen-sharing feature this app
/// ships. So it is a counted hold that a route takes while it is on screen and
/// gives back when it leaves. A phrase on screen DURING a screen share still
/// goes black — that is the flag doing its job, not a regression.
class SecureScreen {
  SecureScreen({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'xveil/secure_screen';

  final MethodChannel _channel;

  /// Who is currently asking for it. Counted rather than a bool: two guarded
  /// routes can overlap (a dialog over a phrase screen), and the first one to
  /// close must not lift the flag off the one still showing.
  final Set<Object> _holders = <Object>{};

  bool get engaged => _holders.isNotEmpty;

  int get holderCount => _holders.length;

  /// Whether the PLATFORM is currently holding the flag, as distinct from
  /// whether this app wants it to (audit report10 X-06).
  ///
  /// They used to be the same bit. `hold` called the platform only on the
  /// transition into engaged, and a `PlatformException` there was swallowed —
  /// so a failed first hold left the app believing a screen was protected
  /// while nothing had been applied, and no later hold retried because the
  /// transition had already happened. A silent fail-open on the one control
  /// that stands between a recovery certificate and a screenshot.
  bool get secured => _applied == true;
  bool? _applied = false;

  /// Serialize platform updates when holders or capture permission change.
  Future<void>? _syncing;

  /// Take a hold. The platform is told whenever it is not already holding —
  /// not only on the first holder, so a call that failed is retried by the
  /// next screen that needs it rather than never again.
  Future<void> hold(Object holder) {
    _holders.add(holder);
    return _sync();
  }

  /// Give it back. The platform is told when the last hold goes.
  Future<void> release(Object holder) {
    return _holders.remove(holder) ? _sync() : Future<void>.value();
  }

  Future<void> _sync() {
    if (_syncing case final pending?) return pending;
    if (_applied == engaged) return Future<void>.value();
    return _syncing = _syncPlatform();
  }

  Future<void> _syncPlatform() async {
    try {
      while (_applied != engaged) {
        final wanted = engaged;
        final applied = await _apply(wanted);
        _applied = applied ? wanted : null;
        if (!applied && wanted == engaged) return;
      }
    } finally {
      _syncing = null;
    }
  }

  @visibleForTesting
  void debugReset() {
    _holders.clear();
    _applied = false;
    _syncing = null;
  }

  /// True when the platform took the request, or when there is no platform
  /// side to take it.
  Future<bool> _apply(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
      return true;
    } on MissingPluginException {
      // Windows and Linux, which have no runner-side answer at all. Nothing to
      // do and nothing to shout about: [TaskSwitcherShield] is what covers
      // those. Android answers with `FLAG_SECURE`, iOS with a cover while the
      // screen is being recorded, macOS with `NSWindow.sharingType`.
      //
      // Reported as applied ON PURPOSE. There is nothing to retry on these
      // platforms, and treating it as a failure would put a channel call in
      // front of every hold forever, on the two platforms where it can never
      // succeed.
      return true;
    } on PlatformException {
      // The window may be gone (a route torn down during a lifecycle change).
      // Not an error to shout about — but not a success either: the next hold
      // tries again, because the alternative is a screen the app believes is
      // protected and is not.
      return false;
    }
  }
}

/// The app-wide instance. A plain global for the same reason the error journal
/// is: a route has to reach it without a provider scope in the way.
final secureScreen = SecureScreen();

/// Capture permission for the current app profile, including its lock screen.
class ProtectedScreenCapturePolicy extends InheritedWidget {
  const ProtectedScreenCapturePolicy({
    super.key,
    required this.allowed,
    required super.child,
  });

  final bool allowed;

  static bool isAllowed(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProtectedScreenCapturePolicy>()
          ?.allowed ??
      false;

  @override
  bool updateShouldNotify(ProtectedScreenCapturePolicy oldWidget) =>
      oldWidget.allowed != allowed;
}

/// Holds the secure-screen flag for as long as [child] is mounted.
///
/// Mount-scoped rather than route-scoped on purpose: a route can be popped,
/// replaced or thrown away by a rebuild, and `dispose` is the one moment that
/// happens in every one of those cases.
class SecureScreenGuard extends StatefulWidget {
  const SecureScreenGuard({super.key, required this.child, this.controller});

  final Widget child;

  /// Test seam. Production always uses the app-wide [secureScreen].
  final SecureScreen? controller;

  @override
  State<SecureScreenGuard> createState() => _SecureScreenGuardState();
}

class _SecureScreenGuardState extends State<SecureScreenGuard> {
  SecureScreen? _heldBy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = ProtectedScreenCapturePolicy.isAllowed(context)
        ? null
        : widget.controller ?? secureScreen;
    if (identical(controller, _heldBy)) return;
    _heldBy?.release(this);
    _heldBy = controller;
    controller?.hold(this);
  }

  @override
  void dispose() {
    _heldBy?.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A neutral cover over the whole app while it is not in the foreground.
///
/// The task switcher shows a snapshot of the last frame, and where nothing
/// native answers that snapshot is the only remaining way the last open chat
/// leaves the device — someone holding the phone sees it without unlocking
/// anything.
///
/// Best-effort, and worth saying plainly: the platform decides when it takes
/// its snapshot, and a frame drawn on the way out is not guaranteed to land
/// first. That is exactly why the iOS runner puts up its OWN cover in
/// `willResignActive`, where being in the snapshot is guaranteed rather than
/// raced. This stays as the cross-platform floor — Windows and Linux have
/// nothing else — and [SecureScreenGuard] is what actually forbids the capture
/// on the platforms that offer to.
///
/// Deliberately blank apart from the app name: a cover that said "locked" would
/// announce that there is something to unlock.
class TaskSwitcherShield extends StatefulWidget {
  const TaskSwitcherShield({super.key, required this.child});

  final Widget child;

  @override
  State<TaskSwitcherShield> createState() => _TaskSwitcherShieldState();
}

class _TaskSwitcherShieldState extends State<TaskSwitcherShield>
    with WidgetsBindingObserver {
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is the one that matters and the one that is easy to miss: it
    // is the state the app is in WHILE the switcher is being drawn, before
    // `paused` ever arrives. Covering only on `paused` covers nothing.
    final cover = switch (state) {
      AppLifecycleState.inactive ||
      AppLifecycleState.paused ||
      AppLifecycleState.hidden => true,
      AppLifecycleState.resumed || AppLifecycleState.detached => false,
    };
    if (cover != _covered) setState(() => _covered = cover);
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // `ExcludeSemantics` used to sit on the COVER — which hid the cover from
      // a screen reader and left everything underneath it perfectly readable,
      // the opposite of what a cover is for (audit IF-02). What has to be
      // silenced is the tree below, and the pointer and focus with it.
      FocusScope(
        canRequestFocus: !_covered,
        child: ExcludeSemantics(
          excluding: _covered,
          child: IgnorePointer(ignoring: _covered, child: widget.child),
        ),
      ),
      if (_covered)
        const Positioned.fill(
          // Blocks what is painted beneath; the cover itself still says nothing
          // of its own, for the reason in [_NeutralCover].
          child: BlockSemantics(
            child: ExcludeSemantics(child: _NeutralCover()),
          ),
        ),
    ],
  );
}

class _NeutralCover extends StatelessWidget {
  const _NeutralCover();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      // The product name and nothing else — the same string the switcher
      // already prints under the card, so the cover adds no fact of its own.
      // Not localized because the name is not.
      child: Center(
        child: Text(
          'xVeil',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
