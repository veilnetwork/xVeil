// The three credentials the devices screen puts on the system-wide clipboard,
// and the two routes each of them had onto it.
//
// The recovery CERTIFICATE, the recovery CODE and the device-adoption TOKEN
// were copied with no lifetime at all: they sat on a clipboard that is shared
// with every app on the device, survives the lock screen, and on both Apple
// and Windows syncs to other machines. The certificate and the code together
// are a whole recovery capability for the identity — the sheet's own warning
// says "anyone with both values controls your sovereign device identity" —
// and unlike the API token, which was bounded first, a sovereign recovery
// capability cannot be revoked from the screen that minted it.
//
// Giving each of them a SecretCopyButton bounded ONE route and left a second
// one open, because the same three values were also rendered in
// `SelectableText`. That widget is an `EditableText` in read-only clothes:
// long-press → Copy on a phone and Ctrl/Cmd-C on a desktop both land in
// `Clipboard.setData` inside the framework, with no timer, no snackbar and no
// bound. The button was bounded, the text beside it was not, and nothing in
// this file could see the difference — see the note on the source checks at
// the bottom, which is the lesson this file is really carrying.
//
// So three things are gated here, because each one alone passes while the
// person is still exposed:
//
//  * the BEHAVIOUR of the control — it writes the secret, schedules the clear,
//    and says the window in the same breath, so nothing is taken away silently;
//  * the BEHAVIOUR of the display — the secret on screen offers no copy of its
//    own, by long-press, by keyboard, or through an ancestor selection;
//  * the ROUTING — that all three credentials actually use both. A perfect
//    pair of widgets nothing uses is the defect unchanged, and this is the
//    half no widget test here can see: those sheets are private and need a
//    live GroupService and RealVeilStack to open.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/clipboard_secret.dart';
import 'package:xveil/features/settings/devices_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The copy the framework offers on selected text, by the two routes it
  /// offers it: the toolbar item and the shortcut that never builds one.
  Future<void> longPressThenCopyShortcut(
    WidgetTester tester,
    Finder target,
  ) async {
    await tester.longPress(target);
    await tester.pumpAndSettle();
    // Ctrl-C rather than Cmd-C: flutter_test runs as TargetPlatform.android
    // unless told otherwise, and that is the binding DefaultTextEditingShortcuts
    // installs there. This is the route a `contextMenuBuilder` patch would have
    // missed entirely — `copySelection` is reached with no toolbar ever built.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  group('the copy control', () {
    testWidgets('copying a credential also schedules taking it back off', (
      tester,
    ) async {
      var scheduled = 0;
      await pump(
        tester,
        SecretCopyButton(
          label: 'Copy certificate',
          value: () => 'CERTIFICATE-BYTES',
          copiedMessage: (s) => 'cleared in $s',
          schedule: () async => scheduled++,
        ),
      );

      await tester.tap(find.byType(SecretCopyButton));
      await tester.pumpAndSettle();

      expect(copied, ['CERTIFICATE-BYTES']);
      expect(
        scheduled,
        1,
        reason: 'the secret is on a clipboard every app can read and nothing '
            'will ever take it off',
      );
    });

    testWidgets('the person is told the window before it starts', (
      tester,
    ) async {
      // The clear is unconditional — clipboard_secret.dart explains why a
      // compare-then-clear would raise an iOS "pasted from xVeil" banner every
      // time — so something else copied inside the window is lost. That cost is
      // only fair if it is stated, and stated with the SAME number the timer
      // waits, which is why the message takes the seconds rather than spelling
      // one out.
      await pump(
        tester,
        SecretCopyButton(
          label: 'Copy',
          value: () => 'secret',
          copiedMessage: (s) => 'The clipboard will be cleared in $s seconds.',
          schedule: () async {},
        ),
      );

      await tester.tap(find.byType(SecretCopyButton));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'The clipboard will be cleared in '
          '${kClipboardSecretLifetime.inSeconds} seconds.',
        ),
        findsOneWidget,
        reason: 'a clipboard that empties itself with no warning looks like a '
            'bug and costs the person whatever they had copied',
      );
    });

    testWidgets('the value is read at tap time, not captured at build', (
      tester,
    ) async {
      // These sheets rebuild around the secret as it is produced. A value
      // captured at build time would copy the previous frame's — for the
      // adoption token, a token for a device that is no longer the one being
      // adopted.
      var current = 'first';
      await pump(
        tester,
        SecretCopyButton(
          label: 'Copy',
          value: () => current,
          copiedMessage: (s) => 'cleared in $s',
          schedule: () async {},
        ),
      );
      current = 'second';
      await tester.tap(find.byType(SecretCopyButton));
      await tester.pumpAndSettle();

      expect(copied, ['second']);
    });
  });

  group('the secret on screen offers no copy of its own', () {
    const secret = 'SOVEREIGN-RECOVERY-CERTIFICATE-BYTES';

    testWidgets('a selectable widget here really would offer one', (
      tester,
    ) async {
      // The calibration for every negative assertion below, and the reason
      // they are not vacuous. If a future Flutter stops raising the toolbar
      // under `tester.longPress`, or stops routing Ctrl-C without focus, this
      // test goes red and says so — instead of the three below quietly
      // passing because nothing at all happens in this harness.
      //
      // It is also the defect itself, reproduced: this is exactly what stood
      // beside each SecretCopyButton.
      await pump(tester, const SelectableText(secret));
      await longPressThenCopyShortcut(tester, find.text(secret));

      expect(
        find.text('Copy'),
        findsOneWidget,
        reason: 'the framework toolbar no longer appears in this harness, so '
            'the "no Copy" assertions below prove nothing',
      );
      expect(
        find.byType(EditableText),
        findsOneWidget,
        reason: 'SelectableText no longer builds an EditableText, so the '
            'by-type assertions below prove nothing',
      );
      expect(
        copied,
        [secret],
        reason: 'the framework no longer reaches the clipboard by itself, so '
            'the clipboard assertions below prove nothing',
      );
    });

    testWidgets('long-press and Ctrl-C reach nothing', (tester) async {
      await pump(tester, const SecretText(secret));
      await longPressThenCopyShortcut(tester, find.text(secret));

      expect(
        find.text('Copy'),
        findsNothing,
        reason: 'a selection toolbar over the secret is a copy with no timer, '
            'no snackbar and no bound — the SecretCopyButton beside it is the '
            'only route that clears itself',
      );
      expect(
        find.byType(AdaptiveTextSelectionToolbar),
        findsNothing,
        reason: 'a selection toolbar was raised over the secret',
      );
      expect(
        find.byType(EditableText),
        findsNothing,
        reason: 'by TYPE rather than by widget name on purpose: SelectableText, '
            'a TextField turned read-only, and anything else built on '
            'EditableText all carry the same framework copy, and the point is '
            'to catch the next one as well as the last one',
      );
      expect(
        find.byType(SelectableRegion),
        findsNothing,
        reason: 'SelectionArea copies without an EditableText anywhere, which '
            'is why the type check above is not enough on its own',
      );
      expect(
        copied,
        isEmpty,
        reason: 'the secret reached the system-wide clipboard without anyone '
            'pressing the control that bounds how long it stays there',
      );
    });

    testWidgets('an ancestor SelectionArea cannot reach it either', (
      tester,
    ) async {
      // There is no SelectionArea over these sheets today. This is what stops
      // that from being a fact somebody has to keep remembering: a sheet
      // wrapped in one tomorrow makes every other line selectable and leaves
      // the three secrets exactly where they are.
      await pump(
        tester,
        const SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [SecretText(secret), Text('ORDINARY-EXPLANATORY-LINE')],
          ),
        ),
      );

      await longPressThenCopyShortcut(tester, find.text(secret));
      expect(
        find.text('Copy'),
        findsNothing,
        reason: 'long-pressing the secret started a selection over it and '
            'offered to copy it',
      );
      expect(
        copied.join('\n'),
        isNot(contains(secret)),
        reason: 'select-all under the ancestor selection swept the secret up '
            'with everything else and put it on the clipboard unbounded',
      );
      // The other half of the same assertion, and what keeps it from being
      // vacuous: that select-all DID take the ordinary line beside it. The
      // region is live, it copied everything it could reach, and the secret
      // was not among it.
      expect(
        copied.join('\n'),
        contains('ORDINARY-EXPLANATORY-LINE'),
        reason: 'the SelectionArea in this fixture selects nothing at all, so '
            'the assertion above proves nothing',
      );
    });
  });

  group('every credential on the devices screen is routed through both', () {
    // Source checks, and they are here because the sheets cannot be pumped:
    // they are private and take a live GroupService and RealVeilStack, and
    // devices_screen_test.dart already records that the positive case is out
    // of reach. What they can and cannot see is worth being exact about.
    final source = File(
      'lib/features/settings/devices_screen.dart',
    ).readAsStringSync();

    /// The expression each credential is displayed and copied from, and the
    /// name to say when it is the one that lost its cover.
    const credentials = {
      '_certificate!': 'the recovery certificate',
      '_code!': 'the recovery code',
      '_token!': 'the device-adoption token',
    };

    test('each of them is displayed by SecretText', () {
      final bare = <String>[];
      for (final entry in credentials.entries) {
        if (!source.contains('SecretText(${entry.key}')) {
          bare.add('${entry.value} (${entry.key})');
        }
      }
      expect(
        bare,
        isEmpty,
        reason: 'these are shown in something other than SecretText, and every '
            'other way of putting text on screen that a finger can grab hands '
            'it to the clipboard with no lifetime at all:\n  '
            '${bare.join("\n  ")}',
      );
    });

    test('nothing on this screen is selectable', () {
      // Whole-file rather than per-credential: the defect was not that one
      // variable was spelled a particular way, it was that a selectable widget
      // stood next to a bounded button. Neither of these belongs on a screen
      // whose sheets exist to show recovery capabilities.
      final offenders = [
        for (final widget in ['SelectableText(', 'SelectionArea('])
          if (source.contains(widget)) widget,
      ];
      expect(
        offenders,
        isEmpty,
        reason: 'these put a framework copy — long-press and Ctrl/Cmd-C, no '
            'timer, no snackbar, no bound — beside credentials that the sheet '
            'is wrapped in SecureScreenGuard to protect:\n  '
            '${offenders.join("\n  ")}',
      );
    });

    test('each of them is copied by a SecretCopyButton', () {
      // The opposite mistake to the one above: a credential that stops being
      // copied bare because its control was deleted is not a fix, and a
      // credential copied by some third route would slip past the check below.
      final unrouted = <String>[];
      for (final entry in credentials.entries) {
        if (!source.contains('value: () => ${entry.key}')) {
          unrouted.add('${entry.value} (${entry.key})');
        }
      }
      expect(
        unrouted,
        isEmpty,
        reason: 'these are not copied through SecretCopyButton:\n'
            '  ${unrouted.join("\n  ")}',
      );
    });

    test('no call site substitutes its own scheduler', () {
      // `schedule` exists so a test does not wait 45 seconds. A production
      // call site passing its own would satisfy every check here while
      // leaving the credential on the clipboard forever, which is the exact
      // defect wearing the fix's clothes.
      expect(
        source.contains('schedule:'),
        isFalse,
        reason: 'a copy control on this screen overrides the clipboard '
            'lifetime; the default is the only correct one in production',
      );
    });

    test('none of them is handed to the clipboard bare', () {
      // NOT COVERAGE, and kept only because it is cheap. This assertion —
      // and the shape of it, a grep for the literal text of the original
      // three `Clipboard.setData(ClipboardData(text: _certificate!` calls —
      // passed happily for the entire life of the SelectableText defect and
      // would pass again the moment someone reintroduced it. A copy that
      // happens INSIDE the framework has no call site in this file to grep
      // for, so no assertion written this way can ever see one. That is what
      // the widget tests above are for; this one only rules out the one
      // spelling of the mistake that was made once already.
      final bare = <String>[];
      for (final entry in credentials.entries) {
        if (source.contains('Clipboard.setData(ClipboardData(text: '
            '${entry.key}')) {
          bare.add('${entry.value} (${entry.key})');
        }
      }
      expect(
        bare,
        isEmpty,
        reason:
            'these go straight onto the system-wide clipboard and are never '
            'taken off:\n  ${bare.join("\n  ")}\n'
            'Copy them with SecretCopyButton, which schedules the clear and '
            'states the window.',
      );
    });
  });
}
