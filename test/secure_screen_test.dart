import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/secure_screen.dart';
import 'package:xveil/state/android_screen_capture.dart';

/// Every label the platform would hand to VoiceOver / TalkBack, read out of the
/// SEMANTICS tree rather than the widget tree — a cover made of pixels does not
/// appear in that tree at all, which is how the app underneath stayed readable.
List<String> _accessibleLabels(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final label = node.getSemanticsData().label;
    if (label.isNotEmpty) labels.add(label);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byType(MaterialApp)));
  return labels;
}

/// Screenshots, recordings, and the card the task switcher draws.
///
/// The manifest already keeps app data on the device (`allowBackup="false"`,
/// data-extraction rules) but the SCREEN was outside that perimeter — no
/// `FLAG_SECURE` anywhere in the app (audit X-11), on the screen that shows the
/// recovery phrase.
///
/// The fix has to be per-route, and the reason is not style: `FLAG_SECURE`
/// blacks out the window inside the app's own `MediaProjection`, so a global
/// flag would ship screen sharing that shares a black rectangle. Hence the
/// positive test below — the one that would catch "fixed it, broke the
/// feature".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> secureCalls;

  setUp(() {
    secureCalls = [];
    secureScreen.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(SecureScreen.channelName),
          (call) async {
            if (call.method == 'setSecure') {
              secureCalls.add((call.arguments as Map)['secure'] as bool);
            }
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(SecureScreen.channelName),
          null,
        );
    secureScreen.debugReset();
  });

  group('a platform that refuses is retried, not believed', () {
    // audit report10 X-06. The flag used to be told to the platform only on the
    // transition into engaged, and a PlatformException there was swallowed: the
    // app believed a screen was protected while nothing had been applied, and
    // no later hold retried because the transition had already happened.

    void answerWith(Object? Function(bool secure) reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(SecureScreen.channelName),
            (call) async {
              if (call.method != 'setSecure') return null;
              final secure = (call.arguments as Map)['secure'] as bool;
              secureCalls.add(secure);
              final answer = reply(secure);
              if (answer is PlatformException) throw answer;
              return null;
            },
          );
    }

    test('a refused hold does not read as protected', () async {
      answerWith((_) => PlatformException(code: 'no-window'));
      final screen = SecureScreen();
      await screen.hold('a');
      expect(screen.engaged, isTrue, reason: 'the app still wants it');
      expect(
        screen.secured,
        isFalse,
        reason: 'nothing was applied — saying otherwise is the fail-open',
      );
    });

    test('the next hold tries again', () async {
      var fail = true;
      answerWith((_) => fail ? PlatformException(code: 'no-window') : null);
      final screen = SecureScreen();
      await screen.hold('a');
      expect(secureCalls, [true]);

      fail = false;
      await screen.hold('b');
      // Two calls, not one: the second holder is what retries. Under the old
      // shape this was a single call and the second hold was a no-op.
      expect(secureCalls, [true, true]);
      expect(screen.secured, isTrue);
    });

    test('once applied, further holds do not call the platform again', () async {
      // The positive control for the retry: without it, "retries" could mean
      // "calls the platform on every hold forever", which is a channel round
      // trip per screen for nothing.
      answerWith((_) => null);
      final screen = SecureScreen();
      await screen.hold('a');
      await screen.hold('b');
      await screen.hold('c');
      expect(secureCalls, [true]);
    });

    test('a platform with no answer at all is not retried', () async {
      // Windows and Linux. There is nothing to apply and nothing will ever
      // succeed, so treating it as failure would put a channel call in front
      // of every hold forever.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(SecureScreen.channelName),
            null,
          );
      final screen = SecureScreen();
      await screen.hold('a');
      expect(screen.secured, isTrue);
    });

    test('releasing the last hold clears both the want and the flag', () async {
      answerWith((_) => null);
      final screen = SecureScreen();
      await screen.hold('a');
      await screen.release('a');
      expect(screen.engaged, isFalse);
      expect(secureCalls, [true, false]);
      // Left true, the next hold would skip the platform call it needs.
      expect(screen.secured, isFalse);
    });
  });

  // Shaped like the real app root (lib/app.dart): the shield wraps everything,
  // so a "just make it global" implementation would show up here.
  Widget host(Widget child) =>
      MaterialApp(home: TaskSwitcherShield(child: Scaffold(body: child)));

  group('a route that carries a secret', () {
    testWidgets('takes the flag while it is on screen and gives it back', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const SecureScreenGuard(child: Text('24 words'))),
      );
      await tester.pumpAndSettle();
      expect(secureCalls, [true], reason: 'the platform was never asked');

      // Navigating away — here, replacing the tree — must lift it.
      await tester.pumpWidget(host(const Text('chats')));
      await tester.pumpAndSettle();
      expect(secureCalls, [true, false]);
    });

    testWidgets('two overlapping holders do not lift it early', (tester) async {
      // A dialog over the phrase screen. The first to close must not uncover
      // the one still showing.
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              SecureScreenGuard(child: Text('phrase')),
              SecureScreenGuard(child: Text('dialog')),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(secureCalls, [true], reason: 'asked once, not twice');
      expect(secureScreen.holderCount, 2);

      await tester.pumpWidget(
        host(const Column(children: [SecureScreenGuard(child: Text('phrase'))])),
      );
      await tester.pumpAndSettle();
      expect(
        secureCalls,
        [true],
        reason: 'the phrase is still on screen — the flag must stay',
      );

      await tester.pumpWidget(host(const Text('chats')));
      await tester.pumpAndSettle();
      expect(secureCalls, [true, false]);
      expect(secureScreen.engaged, isFalse);
    });

    testWidgets('a platform without the flag is not an error', (tester) async {
      // Desktop and iOS have no equivalent; the channel is simply not there.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(SecureScreen.channelName),
            null,
          );
      await tester.pumpWidget(
        host(const SecureScreenGuard(child: Text('24 words'))),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(secureScreen.engaged, isTrue);
    });
  });

  group('screen sharing still works', () {
    // The audit's own recommendation — a global FLAG_SECURE — would break this.
    // A user sharing their screen would send a black rectangle and never learn
    // why, and no test in the suite would have noticed.

    testWidgets('an ordinary screen never asks for the flag', (tester) async {
      await tester.pumpWidget(
        host(const Column(children: [Text('chats'), Text('a message')])),
      );
      await tester.pumpAndSettle();
      expect(
        secureCalls,
        isEmpty,
        reason: 'nothing may be secured app-wide: the window would go black '
            'inside this app\'s own MediaProjection',
      );
      expect(secureScreen.engaged, isFalse);
    });

    testWidgets('capture starts, and delivers frames, with no flag held', (
      tester,
    ) async {
      await tester.pumpWidget(host(const Text('chats')));
      await tester.pumpAndSettle();

      const captureChannel = MethodChannel('xveil/screen_capture');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        captureChannel,
        (call) async => call.method == 'start' ? true : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(captureChannel, null),
      );

      final frames = <List<int>>[];
      final capture = AndroidScreenCapture(
        () {},
        channel: captureChannel,
        isAndroid: true,
      );
      final started = await capture.start((y, u, v, w, h) => frames.add(y));
      expect(started, isTrue, reason: 'screen sharing must still start');

      // And a real frame still arrives over the same channel.
      const width = 4;
      const height = 4;
      final payload = Uint8List(8 + width * height + 2 * 2 * 2)
        ..buffer.asByteData().setUint32(0, width)
        ..buffer.asByteData().setUint32(4, height);
      await messenger.handlePlatformMessage(
        'xveil/screen_capture',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('frame', payload),
        ),
        (_) {},
      );
      expect(frames, hasLength(1), reason: 'the shared screen went dark');
      expect(
        secureCalls,
        isEmpty,
        reason: 'sharing must not have been secured out of existence',
      );
      await capture.stop();
    });

    testWidgets('the phrase screen DOES darken a share in progress', (
      tester,
    ) async {
      // Not a regression: while the 24 words are on screen, a peer watching the
      // share must not see them. This is the flag doing exactly its job, and it
      // is scoped so that it ends when the screen does.
      await tester.pumpWidget(
        host(const SecureScreenGuard(child: Text('24 words'))),
      );
      await tester.pumpAndSettle();
      expect(secureCalls, [true]);

      await tester.pumpWidget(host(const Text('chats')));
      await tester.pumpAndSettle();
      expect(
        secureCalls,
        [true, false],
        reason: 'and the share comes back the moment the phrase is gone',
      );
    });
  });

  group('the task switcher', () {
    Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) async {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }

    testWidgets('a neutral cover goes up before the snapshot is taken', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TaskSwitcherShield(child: Scaffold(body: Text('a message'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('a message'), findsOneWidget);
      expect(find.text('xVeil'), findsNothing);

      // `inactive` is the state the app is in WHILE the switcher is drawn.
      // Covering only on `paused` would cover nothing.
      await lifecycle(tester, AppLifecycleState.inactive);
      expect(find.text('xVeil'), findsOneWidget);

      await lifecycle(tester, AppLifecycleState.resumed);
      expect(find.text('xVeil'), findsNothing);
      expect(find.text('a message'), findsOneWidget);
    });

    testWidgets('every backgrounded state is covered', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TaskSwitcherShield(child: Scaffold(body: Text('a message'))),
        ),
      );
      await tester.pumpAndSettle();
      // The platform walks the states in order on the way out; each one has to
      // stay covered, or a single missed case reopens the whole hole.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        await lifecycle(tester, state);
        expect(find.text('xVeil'), findsOneWidget, reason: '$state uncovered');
      }
      // …and on the way back in.
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
      ]) {
        await lifecycle(tester, state);
        expect(find.text('xVeil'), findsOneWidget, reason: '$state uncovered');
      }
      await lifecycle(tester, AppLifecycleState.resumed);
      expect(find.text('xVeil'), findsNothing);
    });

    testWidgets('the cover silences the app under it, not itself', (
      tester,
    ) async {
      // `ExcludeSemantics` used to sit on the COVER, which hid the one widget
      // that had nothing to hide and left the whole app readable underneath.
      // A screen reader walks the semantics tree, not the pixels.
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: TaskSwitcherShield(
            child: Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('are you free tonight'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _accessibleLabels(tester),
        contains('are you free tonight'),
        reason: 'the fixture itself is broken',
      );

      await lifecycle(tester, AppLifecycleState.inactive);
      expect(
        _accessibleLabels(tester),
        isNot(contains('are you free tonight')),
        reason: 'the app under the cover is still being read out',
      );
      semantics.dispose();
    });

    testWidgets('the cover hides the content, it does not sit behind it', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TaskSwitcherShield(child: Scaffold(body: Text('a message'))),
        ),
      );
      await tester.pumpAndSettle();
      await lifecycle(tester, AppLifecycleState.inactive);

      final cover = tester.getRect(find.text('xVeil'));
      final screen = tester.getRect(find.byType(TaskSwitcherShield));
      expect(screen.contains(cover.center), isTrue);
      // The Material cover paints after the child, so it is on top; if it were
      // ordered the other way the snapshot would still show the message.
      final materials = find.descendant(
        of: find.byType(TaskSwitcherShield),
        matching: find.byType(Material),
      );
      expect(tester.widgetList(materials).length, greaterThan(1));
      expect(
        tester.getRect(find.byType(Material).last).size,
        tester.getRect(find.byType(TaskSwitcherShield)).size,
        reason: 'the topmost surface must cover the whole window',
      );
    });
  });
  test('the recovery export sheet is inside the capture guard', () async {
    // The one screen that shows a sovereign recovery capability whole: the
    // certificate AND the code that unlocks it, both copyable. A screenshot or
    // a recording of it reconstructs the signer and mints new device-group
    // state as this identity — a long-lived capability, not a session secret.
    //
    // Structural rather than a widget test: the sheet is private and takes a
    // GroupService, so pumping it needs more scaffolding than the claim is
    // worth. What matters is that the guard encloses BOTH the display and the
    // copy buttons, which is what the ordering assertion below checks.
    final source =
        await File('lib/features/settings/devices_screen.dart').readAsString();

    final guard = source.indexOf('return SecureScreenGuard(');
    expect(
      guard,
      isNonNegative,
      reason: 'the recovery export sheet must be wrapped in SecureScreenGuard',
    );

    for (final secret in ['_certificate!', '_code!']) {
      // Both are shown through SecretText and copied through SecretCopyButton
      // now: the first has no selection to copy from and the second bounds how
      // long the value stays on the clipboard — see
      // devices_clipboard_lifetime_test. The claim here is unchanged: the
      // guard encloses both the display and the control, not merely one.
      final shown = source.indexOf('SecretText($secret');
      final copied = source.indexOf('value: () => $secret');
      expect(shown, isNonNegative, reason: 'display of $secret moved');
      expect(copied, isNonNegative, reason: 'copy button for $secret moved');
      expect(
        copied,
        greaterThan(guard),
        reason: '$secret is copied outside the guard',
      );
      expect(
        shown,
        greaterThan(guard),
        reason: '$secret is shown outside the guard',
      );
    }
  });

  test('the device-adoption sheet is inside the capture guard too', () async {
    // The recovery sheet was guarded and this one was not, and the reasoning
    // that left it out does not survive being said aloud: a QR is not a
    // picture of a secret, it IS the secret. `QrImageView` is handed the
    // adoption token verbatim, so a screenshot — or a phone camera across a
    // desk, which no flag stops but which the printed token beside it invites
    // anyway — carries the whole capability to adopt a device into this
    // identity's group. The sheet also takes the recovery code or phrase in
    // its first branch, which is the same secret the guarded sheet protects.
    final source =
        await File('lib/features/settings/devices_screen.dart').readAsString();

    final sheet = source.indexOf('class _SourceLinkSheetState');
    expect(sheet, isNonNegative, reason: 'the adoption sheet was renamed');
    // Bounded at the next class so a guard belonging to some later widget
    // cannot be mistaken for this one's.
    final end = source.indexOf('\nclass ', sheet);
    expect(end, greaterThan(sheet));
    final body = source.substring(sheet, end);

    expect(
      body.contains('SecureScreenGuard('),
      isTrue,
      reason: 'the sheet that shows the adoption token, as a QR and as text, '
          'can be screenshotted and screen-recorded',
    );
    final qr = body.indexOf('_linkCodeQr(context, _token!');
    expect(qr, isNonNegative, reason: 'the adoption QR moved');
    expect(
      qr,
      greaterThan(body.indexOf('SecureScreenGuard(')),
      reason: 'the QR is rendered outside the guard',
    );
  });
}
