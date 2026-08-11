// The three credentials the devices screen puts on the system-wide clipboard.
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
// Two things are gated here, because either one alone passes while the person
// is still exposed:
//
//  * the BEHAVIOUR of the control — it writes the secret, schedules the clear,
//    and says the window in the same breath, so nothing is taken away silently;
//  * the CALL SITES — that all three credentials actually go through that
//    control. A perfect button nothing uses is the defect unchanged, and this
//    is the half that the widget test cannot see: those sheets are private and
//    need a live GroupService and RealVeilStack to open.

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

  Future<void> pump(
    WidgetTester tester,
    SecretCopyButton button,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(body: Center(child: button)),
      ),
    );
    await tester.pumpAndSettle();
  }

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

  testWidgets('the person is told the window before it starts', (tester) async {
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

  group('every credential on the devices screen goes through it', () {
    // The screen's own sheets cannot be pumped: they are private and take a
    // live GroupService and RealVeilStack. What CAN be checked, and is the
    // half that actually regressed, is that no credential is handed to the
    // clipboard directly — the shape of the defect was three bare
    // `Clipboard.setData` calls beside a fourth that had been fixed.
    final source = File(
      'lib/features/settings/devices_screen.dart',
    ).readAsStringSync();

    /// The expression each credential is copied from, and the name to say when
    /// it is the one that lost its lifetime.
    const credentials = {
      '_certificate!': 'the recovery certificate',
      '_code!': 'the recovery code',
      '_token!': 'the device-adoption token',
    };

    test('none of them is handed to the clipboard bare', () {
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

    test('each of them is copied by a SecretCopyButton', () {
      // The opposite mistake to the one above: a credential that stops being
      // copied bare because its control was deleted is not a fix, and a
      // credential copied by some third route would slip past the check above.
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
      // call site passing its own would satisfy both checks above while
      // leaving the credential on the clipboard forever, which is the exact
      // defect wearing the fix's clothes.
      expect(
        source.contains('schedule:'),
        isFalse,
        reason: 'a copy control on this screen overrides the clipboard '
            'lifetime; the default is the only correct one in production',
      );
    });
  });
}
