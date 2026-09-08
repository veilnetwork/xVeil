// Copying the 24 words off the device, and what it costs.
//
// The step used to offer no way at all to get the phrase out — screenshots are
// blocked there, deliberately — on the grounds that the clipboard is
// system-wide. The owner asked for the copy anyway (2026-09-08), and the trade
// is stated to the person rather than hidden: the words go on the clipboard
// and come off it 30 seconds later.
//
// What is asserted here is exactly what could silently go wrong:
//
//  * the copy carries ALL 24 words, in the form the restore step accepts — a
//    phrase copied with a word missing is the failure the whole step exists to
//    prevent, and it would look fine on screen;
//  * the person is told the clipboard is shared and when it clears BEFORE they
//    press anything, not afterwards;
//  * pressing it says the window has started.
//
// Not asserted, honestly: the placeholder branch. `real: false` is unreachable
// from the wizard today — the create path sets it true and the link path never
// reaches this step — so a test that walked the UI could not distinguish a
// guard that works from one that is never asked.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

class _NoopNode implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

String phraseOf24() => List.generate(24, (i) => 'word${i + 1}').join(' ');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// What the app handed to the platform clipboard, in order.
  late List<String> copied;

  setUp(() {
    copied = <String>[];
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
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

  Future<AppL10n> openRecovery(WidgetTester tester) async {
    // Roomy on purpose: this test is about the copy, and the layout test next
    // door is what holds the small screens to account.
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: OnboardingScreen(
            validatePhrase: (_) => true,
            generatePhrase: phraseOf24,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(OnboardingScreen)));
    await tester.tap(find.text(l.actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.onboardCreateIdentity));
    await tester.pumpAndSettle();
    expect(find.text(l.recoveryTitle), findsOneWidget);
    return l;
  }

  testWidgets('the copy carries all 24 words, in the form restore accepts', (
    tester,
  ) async {
    final l = await openRecovery(tester);

    await tester.tap(find.text(l.recoveryCopy));
    await tester.pump();

    expect(copied, hasLength(1));
    final words = copied.single.split(' ');
    expect(
      words,
      hasLength(24),
      reason: 'a phrase short of a word restores nothing, and looks fine',
    );
    expect(words.first, 'word1');
    expect(words.last, 'word24');
    expect(copied.single, phraseOf24());

    // The window is real, not a figure of speech: still there before it ends…
    await tester.pump(const Duration(seconds: 20));
    expect(copied, hasLength(1), reason: 'cleared too early to be pasted');

    // …and gone after it. This is the promise the caption makes.
    await tester.pump(const Duration(seconds: 11));
    expect(copied.last, isEmpty, reason: 'the clipboard must be cleared');
  });

  testWidgets('the cost is stated before the copy, not after', (tester) async {
    final l = await openRecovery(tester);

    // Present with no interaction at all: the person reads it while deciding.
    expect(find.text(l.recoveryCopyCaution), findsOneWidget);
    expect(find.text(l.recoveryCopied), findsNothing);

    await tester.tap(find.text(l.recoveryCopy));
    await tester.pump();

    expect(find.text(l.recoveryCopied), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the words the person is told to write are the words copied', (
    tester,
  ) async {
    final l = await openRecovery(tester);
    await tester.tap(find.text(l.recoveryCopy));
    await tester.pump();

    // Every word rendered in the grid must appear in the copy, in order. This
    // is the cross-check the count alone cannot make: 24 words of the WRONG
    // phrase would satisfy the test above.
    for (var i = 0; i < 24; i++) {
      expect(
        find.byKey(recoveryWordKey(i)),
        findsOneWidget,
        reason: 'word ${i + 1} must be on the step',
      );
    }
    expect(copied.first.split(' ')[0], 'word1');
    expect(copied.first.split(' ')[11], 'word12');
    expect(copied.first.split(' ')[23], 'word24');
    await tester.pump(const Duration(seconds: 31));
  });
}
