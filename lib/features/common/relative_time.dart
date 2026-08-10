import '../../l10n/app_localizations.dart';

/// "5 minutes ago", in the reader's language.
///
/// `formatAgo` in `lib/core/format.dart` did this in English and only in
/// English, and its one caller wrapped it in a localised sentence — so a
/// Russian reader got «Последний раз: 5d ago». A translated frame around an
/// untranslated value is the shape that hides this: the line looks localised
/// at a glance.
///
/// It lives here rather than in `core/` because the answer needs `AppL10n`,
/// which pulls in Flutter, and the headless daemon reaches `core/` and must
/// stay Flutter-free (`headless_is_flutter_free_test`).
///
/// The steps are the ones the English version chose and they are kept: a
/// month is thirty days and a year three hundred and sixty-five, because the
/// caller is saying "a while ago" and not measuring. Every unit above a minute
/// goes through a plural form, which is the part English does not need and
/// Russian does.
String formatAgoL10n(AppL10n l, Duration d) {
  if (d.inSeconds < 60) return l.agoJustNow;
  if (d.inMinutes < 60) return l.agoMinutes(d.inMinutes);
  if (d.inHours < 24) return l.agoHours(d.inHours);
  if (d.inDays < 30) return l.agoDays(d.inDays);
  final months = d.inDays ~/ 30;
  if (months < 12) return l.agoMonths(months);
  return l.agoYears(d.inDays ~/ 365);
}
