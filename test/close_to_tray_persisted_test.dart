import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/state/close_to_tray_controller.dart';

/// A stored "do not hide to tray" has to survive a restart.
///
/// Riverpod builds a Notifier on its first read, and `build()` is
/// synchronous, so it answers with the optimistic default while the stored
/// value is still being read. Only two places touch this provider: the chats
/// settings screen, and the window-close handler. On a launch where the user
/// does not open that screen, the close handler's read IS the first one — so
/// the answer was the default, every time, and the preference the user set
/// was silently ignored from the second launch onwards.
///
/// Measured on the Windows ARM64 stand: the preference file held
/// `close_to_tray: false` and the window went to the tray anyway.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the stored answer survives being asked first', () async {
    SharedPreferences.setMockInitialValues({'close_to_tray': false});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // THE FIRST TOUCH of the provider in this container, exactly as a cold
    // start reaches it: nothing has read or watched it before.
    final answer = await container
        .read(closeToTrayProvider.notifier)
        .resolved();

    expect(
      answer,
      isFalse,
      reason:
          'the close handler was told to hide to tray by a default the user '
          'had already overridden',
    );
  });

  /// Vacuity: the same first touch, read synchronously, is what shipped —
  /// and it answers with the default. Without this the test above would pass
  /// against a `resolved()` that simply returned the stored value by luck of
  /// timing rather than by waiting for it.
  test('a synchronous first read still answers with the default', () {
    SharedPreferences.setMockInitialValues({'close_to_tray': false});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(closeToTrayProvider),
      isTrue,
      reason:
          'if a synchronous read now answers correctly, the load became '
          'synchronous and resolved() no longer proves anything — re-aim '
          'this guard',
    );
  });

  /// Nothing stored keeps the documented default: hide to tray.
  test('an unset preference still hides to tray', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container.read(closeToTrayProvider.notifier).resolved(),
      isTrue,
    );
  });

  /// A choice made in this session wins over the stored one, whichever lands
  /// first — `set` marks the value as the user's and the load must not undo it.
  test('a choice made now is not overwritten by the load', () async {
    SharedPreferences.setMockInitialValues({'close_to_tray': true});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(closeToTrayProvider.notifier);
    await controller.set(false);
    expect(await controller.resolved(), isFalse);
  });

  /// The close handler must not go back to a synchronous read. A comment
  /// cannot hold this: `ref.read(closeToTrayProvider)` compiles, runs, and is
  /// wrong only on the first launch after the user changes the setting.
  test('the window-close handler asks for the resolved answer', () {
    final source = File('lib/desktop/desktop_tray.dart').readAsStringSync();
    final start = source.indexOf('void onWindowClose()');
    expect(
      start,
      isNot(-1),
      reason: 'onWindowClose moved or was renamed; re-aim this guard',
    );
    final body = source.substring(start, source.indexOf('\n  }', start));
    expect(
      body.contains('closeToTrayProvider.notifier).resolved()'),
      isTrue,
      reason:
          'onWindowClose must await the persisted answer; a synchronous read '
          'is the default on a cold start',
    );
    expect(
      body.contains('ref.read(closeToTrayProvider)'),
      isFalse,
      reason: 'the synchronous read came back',
    );
  });
}
