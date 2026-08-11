// Taking a copied credential back off the clipboard.
//
// audit report10 X-07. A write-capable API token went to the system-wide
// clipboard and stayed there: shared with every app, surviving the screen
// lock, read by history tools and synced to other machines by the OS.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/clipboard_secret.dart';

void main() {
  test('the clipboard is cleared, and only after the window', () async {
    var cleared = false;
    Duration? waited;
    await clearClipboardLater(
      after: const Duration(seconds: 45),
      delay: (d) async {
        waited = d;
        // Ordering is the property: clearing before the wait would take the
        // token away while the person is still switching windows to paste it.
        expect(cleared, isFalse, reason: 'cleared before the window elapsed');
      },
      clear: () async => cleared = true,
    );
    expect(waited, const Duration(seconds: 45));
    expect(cleared, isTrue);
  });

  test('a platform that refuses does not throw at the person', () async {
    // This runs long after the screen is gone; an exception here surfaces
    // nowhere useful and can take the app with it.
    await expectLater(
      clearClipboardLater(
        delay: (_) async {},
        clear: () async => throw PlatformException(code: 'no-clipboard'),
      ),
      completes,
    );
    await expectLater(
      clearClipboardLater(
        delay: (_) async {},
        clear: () async => throw MissingPluginException(),
      ),
      completes,
    );
  });

  test('the window is short enough to matter and long enough to use', () {
    // Pinned, because the number is stated to the person in the snackbar: a
    // silent change here makes the interface tell them something untrue.
    expect(kClipboardSecretLifetime.inSeconds, 45);
  });
}
