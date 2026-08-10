// "5 minutes ago", in the reader's language.
//
// The English-only `formatAgo` had exactly one caller, and that caller wrapped
// it in a LOCALISED sentence: `l.devicesLastSeen(formatAgo(away))`. So a
// Russian reader was shown «Последний раз: 5d ago» — a translated frame around
// an untranslated value, which is the shape that hides this kind of thing.
// The line looks localised at a glance.
//
// Russian is the reason the units go through plural forms rather than through
// "{n} minutes": it needs one/few/other where English needs none.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/common/relative_time.dart';
import 'package:xveil/l10n/app_localizations.dart';

Future<AppL10n> _l10n(WidgetTester tester, Locale locale) async {
  late AppL10n captured;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: Builder(
        builder: (context) {
          captured = AppL10n.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('every shipped language answers in its own words', (
    tester,
  ) async {
    final seen = <String, String>{};
    for (final locale in AppL10n.supportedLocales) {
      final l = await _l10n(tester, locale);
      final rendered = formatAgoL10n(l, const Duration(minutes: 5));
      expect(
        rendered.trim(),
        isNotEmpty,
        reason: '${locale.languageCode} produced nothing for five minutes',
      );
      seen[locale.languageCode] = rendered;
    }
    // Not merely "each language returned something": each returned something
    // DIFFERENT. A build where the delegates silently fell back to English
    // would satisfy the check above and be exactly the defect.
    expect(
      seen.values.toSet(),
      hasLength(seen.length),
      reason: 'two languages rendered the same text — one fell back: $seen',
    );
  });

  testWidgets('the unit steps are the ones the caller means', (tester) async {
    final l = await _l10n(tester, const Locale('en'));
    expect(formatAgoL10n(l, const Duration(seconds: 59)), l.agoJustNow);
    expect(formatAgoL10n(l, const Duration(minutes: 59)), l.agoMinutes(59));
    expect(formatAgoL10n(l, const Duration(hours: 23)), l.agoHours(23));
    expect(formatAgoL10n(l, const Duration(days: 29)), l.agoDays(29));
    // A month is thirty days and a year three hundred and sixty-five here,
    // deliberately: the caller is saying "a while ago", not measuring.
    expect(formatAgoL10n(l, const Duration(days: 60)), l.agoMonths(2));
    expect(formatAgoL10n(l, const Duration(days: 400)), l.agoYears(1));
  });

  testWidgets('Russian picks the right plural form, which is the whole point', (
    tester,
  ) async {
    final l = await _l10n(tester, const Locale('ru'));
    // one / few / other — the three Russian needs and English does not have.
    final one = formatAgoL10n(l, const Duration(minutes: 1));
    final few = formatAgoL10n(l, const Duration(minutes: 3));
    final many = formatAgoL10n(l, const Duration(minutes: 7));
    expect(one, contains('минуту'));
    expect(few, contains('минуты'));
    expect(many, contains('минут '));
    expect({one, few, many}, hasLength(3));
  });
}
