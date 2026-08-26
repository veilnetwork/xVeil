import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/state/background_node_controller.dart';

void main() {
  test('defaults off and toggles state', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(backgroundNodeProvider), isFalse);

    await c.read(backgroundNodeProvider.notifier).set(true);
    expect(c.read(backgroundNodeProvider), isTrue);

    await c.read(backgroundNodeProvider.notifier).set(false);
    expect(c.read(backgroundNodeProvider), isFalse);
  });

  test('applyIfNodeUp is a safe no-op off-Android', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Never throws regardless of nodeUp (VeilBackground is a no-op off-Android).
    await c.read(backgroundNodeProvider.notifier).applyIfNodeUp(nodeUp: true);
    await c.read(backgroundNodeProvider.notifier).applyIfNodeUp(nodeUp: false);
  });

  /// Turning the switch ON asks the platform to start a foreground service, and
  /// from Android 12 the platform is entitled to REFUSE — `startForeground()`
  /// throws for an app the system does not consider eligible. The write that
  /// remembers the choice used to sit after that call and outside its
  /// protection, so a refusal skipped it: the switch read ON from memory and
  /// snapped back to OFF the next time the notifier was rebuilt, with the node
  /// no longer surviving the screen going off. Seen on a real phone — ON and a
  /// running service at 04:28, OFF and no service at 04:59, same app process.
  group('a platform refusal must not eat the choice', () {
    // Narrower than it may read: with no node in this container `set(true)`
    // never reaches the platform call at all (the premise assertion below says
    // so out loud). What it pins is that the write happens on the ON path.
    // The ordering against a REFUSING platform is the next test.
    test('ON reaches disk', () async {
      SharedPreferences.setMockInitialValues({});
      var started = false;
      final c = ProviderContainer(
        overrides: [
          backgroundServiceProvider.overrideWithValue(
            BackgroundServiceActions(
              start: () async {
                started = true;
                throw StateError('startForeground refused');
              },
              stop: () async {},
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      await c.read(backgroundNodeProvider.notifier).set(true);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('keep_node_background'),
        isTrue,
        reason:
            'the person asked for background operation; a service that will '
            'not start yet is retried on the next node boot, but a choice that '
            'was never written is gone',
      );
      expect(c.read(backgroundNodeProvider), isTrue);
      expect(
        started,
        isFalse,
        reason:
            'premise: no node in this container, so start() is not attempted — '
            'this test is about the write, not about a refusal',
      );
    });

    test('the write happens before the platform call is attempted', () async {
      SharedPreferences.setMockInitialValues({});
      String? persistedWhenCalled;
      final c = ProviderContainer(
        overrides: [
          backgroundServiceProvider.overrideWithValue(
            BackgroundServiceActions(
              start: () async {},
              stop: () async {
                final prefs = await SharedPreferences.getInstance();
                persistedWhenCalled = prefs
                    .getBool('keep_node_background')
                    ?.toString();
                throw StateError('platform refused');
              },
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      // set(false) always reaches the platform call, node up or not.
      await expectLater(
        c.read(backgroundNodeProvider.notifier).set(false),
        throwsStateError,
      );
      expect(
        persistedWhenCalled,
        'false',
        reason:
            'the choice must already be on disk by the time the platform is '
            'asked, so a refusal cannot take it with it',
      );
    });
  });
}
