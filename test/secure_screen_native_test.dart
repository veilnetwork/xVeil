import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/secure_screen.dart';

/// The runner half of the secure screen, on the platforms whose runners answer.
///
/// Shaped like `apple_packet_tunnel_build_test.dart`: none of this can be run
/// here — the iOS half needs a device and the signing blocker is still open —
/// so what the suite CAN hold onto is that the wiring is present and matches
/// the Dart side. Every one of these assertions failed at some point while the
/// runners were being written; the channel name in particular is the kind of
/// typo that costs nothing to make and shows up only as "the flag silently
/// never applied on iOS".
void main() {
  late String ios;
  late String macos;
  late String android;

  setUpAll(() async {
    ios = await File('ios/Runner/AppDelegate.swift').readAsString();
    macos = await File('macos/Runner/MainFlutterWindow.swift').readAsString();
    android = await File(
      'android/app/src/main/kotlin/network/veil/xveil/MainActivity.kt',
    ).readAsString();
  });

  test('every runner answers on the channel Dart actually calls', () {
    // The one fact that binds the four files together. A rename on either side
    // degrades to MissingPluginException, which `SecureScreen` swallows by
    // design — so nothing would go red, and the phrase screen would quietly
    // stop being protected.
    expect(SecureScreen.channelName, 'xveil/secure_screen');
    for (final runner in [ios, macos, android]) {
      expect(runner, contains('xveil/secure_screen'));
    }
  });

  test('every runner handles the method with the argument Dart sends', () {
    for (final runner in [ios, macos, android]) {
      expect(runner, contains('setSecure'));
      expect(runner, contains('"secure"'));
    }
  });

  group('iOS', () {
    test('the cover goes up on the way out, on scenes as well as the app', () {
      // The app-switcher snapshot is taken after this notification. Covering on
      // `didEnterBackground` instead would cover nothing — the picture is
      // already taken by then.
      expect(ios, contains('willResignActiveNotification'));
      expect(ios, contains('UIScene.willDeactivateNotification'));
      expect(ios, contains('didBecomeActiveNotification'));
      expect(ios, contains('UIScene.didActivateNotification'));
    });

    test('the cover is actually added to the window, not just built', () {
      expect(ios, contains('window.addSubview(cover)'));
      expect(ios, contains('bringSubviewToFront(cover)'));
      expect(ios, contains('removeFromSuperview()'));
    });

    test('a guarded route blanks a recording in progress', () {
      // The closest iOS gets to FLAG_SECURE: cover while something is watching.
      expect(ios, contains('capturedDidChangeNotification'));
      expect(ios, contains('isCaptured'));
      expect(ios, contains('setSecureRouteOnScreen'));
    });

    test('the guard is attached before the engine exists', () {
      // A resign-active can arrive during startup, and the switcher cover must
      // not wait for Dart to come up to work.
      final launch = ios.indexOf('didFinishLaunchingWithOptions');
      final attach = ios.indexOf('ScreenPrivacyGuard.shared.attach()');
      final engine = ios.indexOf('didInitializeImplicitFlutterEngine');
      expect(attach, greaterThan(launch));
      expect(attach, lessThan(engine));
    });

    test('the cover says the app name and nothing else', () {
      // Same string the Dart cover uses. A cover that said "locked" would
      // announce that there is something to unlock.
      expect(ios, contains('label.text = "xVeil"'));
      expect(ios, contains('accessibilityElementsHidden'));
    });
  });

  group('macOS', () {
    test('secure toggles the window out of other processes\' reach', () {
      expect(macos, contains('sharingType'));
      expect(macos, contains('secure ? .none : .readOnly'));
    });

    test('it is not set once and left on', () {
      // Permanently `.none` would take this app's own screen sharing out of
      // its own screen share — the exact trap the Android side documents.
      expect(macos, isNot(contains('self.sharingType = .none\n')));
    });
  });
}
