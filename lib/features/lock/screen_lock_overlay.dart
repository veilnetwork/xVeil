import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/secure_screen.dart';
import '../../domain/screen_lock.dart';
import '../../l10n/app_localizations.dart';
import '../../state/screen_lock_controller.dart';

/// Drives the screen lock from the app's lifecycle, and covers the app when it
/// engages.
///
/// A COVER, not a route. That distinction is the whole feature: the router's
/// home shell is what mounts `NotificationBinder`, so redirecting to a lock
/// route would unmount it and messages would stop producing notifications the
/// moment the screen locked — which is precisely the cost the user said they
/// did not want to pay. Everything underneath stays mounted and running; only
/// the pixels are replaced.
class ScreenLockHost extends ConsumerStatefulWidget {
  const ScreenLockHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ScreenLockHost> createState() => _ScreenLockHostState();
}

class _ScreenLockHostState extends ConsumerState<ScreenLockHost>
    with WidgetsBindingObserver {
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
    final controller = ref.read(screenLockProvider.notifier);
    switch (state) {
      // `inactive` counts as leaving. It is the state the app is in while the
      // switcher is drawn and while a system sheet is up, and waiting for
      // `paused` would mean an "immediately" setting did not lock until the
      // app was fully backgrounded.
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        controller.onLeftForeground();
      case AppLifecycleState.resumed:
        controller.onReturnedToForeground();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(screenLockProvider.select((s) => s.locked));
    return Stack(
      children: [
        // The tree below stays MOUNTED — that is the feature — so it has to be
        // made unreachable rather than removed, and "unreachable" has three
        // separate meanings the opaque cover only satisfies one of. A Material
        // absorbs the POINTER. A screen reader walks the SEMANTICS tree, and an
        // external keyboard walks the FOCUS tree; both went straight past the
        // cover and read out (and could activate) the conversation underneath.
        // That is not a corner case: the lock is turned on with two volume keys
        // on an already-unlocked phone, and VoiceOver / TalkBack is exactly what
        // someone holding it would reach for (audit IF-02).
        //
        // Toggled by flags rather than by wrapping conditionally: swapping the
        // widget type on lock would rebuild the whole subtree and throw away the
        // state of everything the cover exists to keep running.
        FocusScope(
          // Without this, Tab from a hardware keyboard walks under the cover.
          canRequestFocus: !locked,
          child: ExcludeSemantics(
            excluding: locked,
            child: IgnorePointer(ignoring: locked, child: widget.child),
          ),
        ),
        if (locked)
          // Belt and braces from the other side: anything painted before this
          // in the same container is dropped from the semantics tree, so a
          // sibling added to this Stack later is covered without remembering to.
          const Positioned.fill(
            child: BlockSemantics(child: ScreenLockCover()),
          ),
      ],
    );
  }
}

/// The password prompt itself.
class ScreenLockCover extends ConsumerStatefulWidget {
  const ScreenLockCover({super.key});

  @override
  ConsumerState<ScreenLockCover> createState() => _ScreenLockCoverState();
}

/// How many whole seconds to SAY are left, from what is actually owed.
///
/// Rounded up, not down: 200ms left displayed as "0 s" is a countdown that
/// spends its last tick claiming the wait is over while the attempt is still
/// being refused, which is the same lie in smaller print.
@visibleForTesting
int screenLockWaitSeconds(Duration owed) => (owed.inMilliseconds / 1000).ceil();

/// Counts how often [ScreenLockCover] rebuilt, so a test can prove the ticker
/// does NOT drag the whole prompt through a rebuild once per tick — the cover
/// carries a password field with live focus and an autofocus, and rebuilding
/// all of it four times a second to change one number is not free.
@visibleForTesting
int screenLockCoverBuilds = 0;

class _ScreenLockCoverState extends ConsumerState<ScreenLockCover> {
  final _controller = TextEditingController();

  /// What the throttle still owes, as its own listenable.
  ///
  /// The value the ticker writes has to reach the screen without a `setState`:
  /// see [screenLockCoverBuilds]. Only the small subtree inside the
  /// [ValueListenableBuilder] below is rebuilt per tick.
  final _owed = ValueNotifier<Duration>(Duration.zero);
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // A debt can predate this widget: the cover is rebuilt whenever the host
    // re-locks, and the failures are counted in the CONTROLLER, which outlives
    // it. Starting at zero would show "wrong password" over a wait already
    // owed — the exact confusion this exists to remove.
    _syncOwed();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _owed.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (ref.read(screenLockProvider.notifier).tryUnlock(_controller.text)) {
      _controller.clear();
    }
    // Either way: a success clears the debt and a failure creates or extends
    // one, and both have to be on screen before the next frame.
    _syncOwed();
  }

  /// Read what is owed now, and run a ticker for exactly as long as some is.
  void _syncOwed() {
    final owed = ref.read(screenLockProvider.notifier).throttleRemaining;
    _owed.value = owed;
    if (owed > Duration.zero) {
      // Four times a second, not once: a countdown driven at exactly its own
      // resolution shows each number for anywhere between 0 and 1 second, and
      // visibly skips one whenever the two clocks drift apart.
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _syncOwed(),
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    screenLockCoverBuilds++;
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final wrong = ref.watch(screenLockProvider.select((s) => s.wrongPassword));
    // The prompt is a screen with a password field on it; the same reasoning
    // that guards the recovery phrase applies to the moment it is typed.
    return SecureScreenGuard(
      // An opaque Material is what stops the tree below being tapped through.
      // It is still mounted and still interactive — that is the point of the
      // feature — so without something absorbing the pointer the lock would be
      // a picture of a lock.
      child: Material(
        color: scheme.surface,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.lock_outline, size: 56, color: scheme.primary),
                    const SizedBox(height: 24),
                    Text(
                      l.screenLockTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 32),
                    // The field and its button, and NOTHING else, are what the
                    // ticker redraws — see [screenLockCoverBuilds].
                    ValueListenableBuilder<Duration>(
                      valueListenable: _owed,
                      builder: (context, owed, _) {
                        final waiting = owed > Duration.zero;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(
                              key: const ValueKey('screen-lock-password'),
                              controller: _controller,
                              obscureText: true,
                              autofocus: true,
                              onSubmitted: (_) => _submit(),
                              decoration: InputDecoration(
                                labelText: l.lockPasswordHint,
                                // The wait WINS over "wrong password", and
                                // that ordering is the whole fix. Inside the
                                // window `tryUnlock` refuses before it looks at
                                // anything, so the CORRECT password comes back
                                // flagged exactly like a wrong one — and the
                                // person, who knows perfectly well what their
                                // password is, is told they do not. The debt is
                                // the true answer, and it is one a person can
                                // act on: wait, then try.
                                errorText: waiting
                                    ? l.screenLockWait(
                                        screenLockWaitSeconds(owed),
                                      )
                                    : (wrong ? l.lockWrong : null),
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              key: const ValueKey('screen-lock-submit'),
                              // Disabled for as long as the answer is fixed.
                              // Leaving it live would keep handing back the
                              // same refusal for a password that is right,
                              // which is what "tapping at a field that
                              // silently ignores them" looks like from the
                              // other side of the screen.
                              onPressed: waiting ? null : _submit,
                              child: Text(l.lockUnlock),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String screenLockTimeoutLabel(AppL10n l, ScreenLockTimeout timeout) =>
    switch (timeout) {
      ScreenLockTimeout.off => l.screenLockOff,
      ScreenLockTimeout.immediately => l.screenLockImmediately,
      ScreenLockTimeout.oneMinute => l.screenLockOneMinute,
      ScreenLockTimeout.fiveMinutes => l.screenLockFiveMinutes,
      ScreenLockTimeout.fifteenMinutes => l.screenLockFifteenMinutes,
    };
