// A theme sent to somebody, and what they see when it arrives.
//
// Sharing a look is a chat action: one person makes a theme, copies it, and
// pastes it into a conversation, usually with a sentence of their own around
// it. Both halves of that have to survive — the theme has to still be a theme
// after a chat has wrapped it and a person has written "try this" in front of
// it, and the sentence has to still be shown as a sentence.
//
// The parsing half is the one with teeth. Prose is made of base64url
// characters too: "enjoy" is a perfectly good base64 run, so a parser that
// took the longest run would swallow the next word and refuse a theme that is
// entirely valid. That is the same defect the recovery certificate had, and
// the same cure — the payload says where it ends.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/theme_spec.dart';
import 'package:xveil/features/chat/shared_theme_card.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/theme_controller.dart';
import 'package:xveil/theme/app_theme.dart';
import 'package:xveil/theme/contrast.dart';

void main() {
  const sent = ThemeSpec(
    id: 'made-by-a-friend',
    name: 'Midnight',
    seed: Color(0xFF7B4A8A),
    dark: true,
    background: Color(0xFF120A18),
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a theme inside a message', () {
    test('words in front of it do not hide it', () {
      final found = ThemeSpec.locate('try this one\n${sent.toText()}');
      expect(found, isNotNull);
      expect(found!.spec, sent);
      expect(found.words, 'try this one');
    });

    test('words AFTER it are not eaten by it', () {
      // The defect this test exists for: every character of "enjoy" is a legal
      // base64url character, so the encoded run does not end where the theme
      // does. It ends where the JSON inside it ends.
      final found = ThemeSpec.locate('${sent.toText()} enjoy');
      expect(
        found,
        isNotNull,
        reason: 'a theme with a word after it is still a theme',
      );
      expect(found!.spec, sent);
      expect(found.words, 'enjoy');
    });

    test('words on both sides, wrapped the way a chat wraps them', () {
      final text = sent.toText();
      final message =
          'made this last night\n'
          '${text.substring(0, 24)}\n${text.substring(24)}\n'
          'tell me what you think';
      final found = ThemeSpec.locate(message);
      expect(found, isNotNull);
      expect(found!.spec, sent);
      expect(found.words, 'made this last night\ntell me what you think');
    });

    test('the encoded part never reaches the reader as words', () {
      final found = ThemeSpec.locate('look: ${sent.toText()}')!;
      expect(found.words.contains(kThemePrefix), isFalse);
      expect(found.words, 'look:');
    });

    test('an ordinary message is not a theme', () {
      for (final body in [
        'hello',
        'see xveil-theme:v1: for details',
        'xveil-recovery:v1:AAAABBBBCCCC',
      ]) {
        expect(ThemeSpec.locate(body), isNull, reason: body);
      }
    });

    test('a truncated theme is not half a theme', () {
      final text = sent.toText();
      expect(ThemeSpec.locate(text.substring(0, text.length - 12)), isNull);
    });
  });

  group('what the bubble shows', () {
    Future<AppL10n> pump(WidgetTester tester, String body) async {
      final found = ThemeSpec.locate(body)!;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Scaffold(body: SharedThemeCard(found: found)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return AppL10n.of(tester.element(find.byType(SharedThemeCard)));
    }

    testWidgets('a theme arrives as a look, not as base64', (tester) async {
      final l = await pump(tester, 'try this\n${sent.toText()}');
      expect(find.text(sent.name), findsWidgets);
      expect(find.text('try this'), findsOneWidget);
      expect(find.text(l.themeInChatUse), findsOneWidget);
      expect(
        find.textContaining(kThemePrefix),
        findsNothing,
        reason: 'the encoded form is for the clipboard, not for a reader',
      );
    });

    testWidgets('the preview shows the warning colour it would really use', (
      tester,
    ) async {
      final l = await pump(tester, sent.toText());
      final sample = tester.widget<Text>(
        find.text(l.themeInChatSampleWarning).first,
      );
      final shown = sample.style!.color!;
      final real = AppTheme.of(sent).colorScheme;
      expect(
        shown.toARGB32(),
        real.error.toARGB32(),
        reason: 'a preview that is not the theme is an advertisement',
      );
      // And the point of showing it at all: it can be read on the surface the
      // theme chose, which is what makes wearing a stranger's colours safe.
      expect(
        contrastRatio(shown, real.surface),
        greaterThanOrEqualTo(kMinTextContrast),
      );
    });

    testWidgets('tapping it puts the app in that theme', (tester) async {
      final l = await pump(tester, sent.toText());
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(SharedThemeCard)),
      );
      expect(scope.read(themeProvider).chosen, kDefaultTheme);

      await tester.tap(find.text(l.themeInChatUse));
      await tester.pumpAndSettle();

      expect(scope.read(themeProvider).chosen, sent);
      expect(
        scope.read(themeProvider).custom,
        contains(sent),
        reason: 'a theme worn from a chat has to survive the next restart',
      );
      expect(find.text(l.themeInChatInUse), findsOneWidget);
      expect(find.text(l.themeInChatUse), findsNothing);
    });

    testWidgets('a built-in sent back is not kept twice', (tester) async {
      // Somebody forwards the theme that ships with the app. Keeping it as
      // "yours" would leave two identical rows in the picker.
      final l = await pump(tester, kBuiltInThemes[3].toText());
      await tester.tap(find.text(l.themeInChatUse));
      await tester.pumpAndSettle();
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(SharedThemeCard)),
      );
      expect(scope.read(themeProvider).chosen, kBuiltInThemes[3]);
      expect(scope.read(themeProvider).custom, isEmpty);
    });
  });
}
