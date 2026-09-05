import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/help/help_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

/// The app explained to somebody who has never met one.
///
/// It had no help of any kind: everything a person needed to know — that there
/// is no account, that a forgotten password cannot be reset, why it sometimes
/// says nobody was found — was either in the source or nowhere.
void main() {
  Future<AppL10n> localised(WidgetTester tester, Locale locale) async {
    late AppL10n l;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) {
            l = AppL10n.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return l;
  }

  testWidgets('every topic has a title and an answer, in every language', (
    tester,
  ) async {
    for (final locale in AppL10n.supportedLocales) {
      final l = await localised(tester, locale);
      final topics = helpTopics(l);
      expect(topics.length, greaterThanOrEqualTo(8), reason: '$locale');
      for (final t in topics) {
        expect(t.title.trim(), isNotEmpty, reason: '$locale');
        // A heading with no answer under it is worse than no heading: it looks
        // like the app has help and then does not answer the question.
        expect(
          t.body.trim().length,
          greaterThan(80),
          reason: 'topic "${t.title}" is a stub in $locale',
        );
      }
    }
  });

  testWidgets('the help is translated, not English in a Russian app', (
    tester,
  ) async {
    // The failure this catches is the ordinary one: a string added to app_en
    // and forgotten in the others, which the generator happily falls back to.
    final en = helpTopics(await localised(tester, const Locale('en')));
    final ru = helpTopics(await localised(tester, const Locale('ru')));
    expect(en.length, ru.length);
    for (var i = 0; i < en.length; i++) {
      expect(
        ru[i].title,
        isNot(en[i].title),
        reason: 'topic $i fell back to English',
      );
      expect(ru[i].body, isNot(en[i].body), reason: 'topic $i body fell back');
    }
  });

  testWidgets('the things a person cannot undo are actually said', (
    tester,
  ) async {
    // Not a style check. These two are the facts that turn into anger when
    // somebody meets them for the first time at the worst moment, and the help
    // exists mostly to say them BEFORE that.
    for (final locale in [const Locale('en'), const Locale('ru')]) {
      final l = await localised(tester, locale);
      final all = helpTopics(l).map((t) => t.body).join('\n').toLowerCase();
      expect(
        all.contains('recovery') ||
            all.contains('восстанов') ||
            all.contains('recuper'),
        isTrue,
        reason: 'nothing in $locale mentions that there is no recovery',
      );
      expect(
        all.contains('password') ||
            all.contains('парол') ||
            all.contains('contraseñ'),
        isTrue,
        reason: 'nothing in $locale explains what the password unlocks',
      );
    }
  });
}
