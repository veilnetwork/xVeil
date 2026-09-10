import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';

import 'device_settings_sync.dart';
import 'identity_scoped_prefs.dart';
import 'providers.dart';

/// PER PROFILE (audit XV-15). A decoy opening in the language the real profile
/// chose is a tell of exactly the kind someone comparing the two would read,
/// and it survived "clear all data".
String get _kLocaleKey => identityScopedPrefKey(kSyncLocale);

/// The app's UI language. `null` means "follow the system locale"; a non-null
/// [Locale] forces that language. Persisted to `shared_preferences` so the
/// choice survives restarts. Watched by [XVeilApp] to drive
/// `MaterialApp.locale`.
class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      final code = prefs.getString(_kLocaleKey);
      if (code != null && code.isNotEmpty) state = Locale(code);
    } catch (_) {
      // No prefs available (e.g. widget tests) — stay on the system locale.
    }
  }

  /// Set the UI language. Pass `null` to follow the system locale.
  Future<void> setLocale(Locale? locale) async {
    state = locale;
    // Device sync: '' = follow the system locale on every device.
    ref
        .read(deviceSettingsSyncHubProvider)
        .notifyLocalSet(kSyncLocale, locale?.languageCode ?? '');
    final prefs = await ref.read(prefsProvider.future);
    if (locale == null) {
      await prefs.remove(_kLocaleKey);
    } else {
      await prefs.setString(_kLocaleKey, locale.languageCode);
    }
  }
}

final localeProvider =
    NotifierProvider<LocaleController, Locale?>(LocaleController.new);

/// The supported locale closest to [wanted], or English.
///
/// `lookupAppL10n` THROWS on a language it has no translation for, and the app
/// supports three. Inside the widget tree that never shows: `MaterialApp`
/// resolves the OS locale against `supportedLocales` before any delegate is
/// asked. Outside it there is no such step, and three places call the lookup
/// directly with a locale nobody filtered — the desktop tray and the two
/// call-notification paths, each because it sits above or beside the tree and
/// has no `Localizations` in scope.
///
/// So a phone set to German reached `lookupAppL10n(Locale('de'))` and got an
/// exception. For the tray that killed the menu refresh; for a call it threw
/// BEFORE `VeilBackground.start`, so the foreground service never came up —
/// and the comment at that call site says what that costs: the OS takes the
/// mic capture and then the process. Observed first as locale `C` in a bare
/// container, which made it look like a container curiosity; it is every user
/// whose system is not English, Spanish or Russian.
///
/// Matching is by language code because that is what the app ships: `ru_RU`
/// and `ru` are the same translation, and a language with none falls back to
/// English rather than refusing to answer.
Locale resolveSupportedLocale(Locale? wanted) {
  if (wanted != null) {
    for (final supported in AppL10n.supportedLocales) {
      if (supported.languageCode == wanted.languageCode) return supported;
    }
  }
  return const Locale('en');
}

/// [lookupAppL10n] that cannot throw on an unsupported locale.
///
/// The one door for code outside the widget tree. Call sites are not trusted
/// to remember the resolution step — that is what went wrong — so the
/// resolution is on this side of the door and
/// `l10n_fallback_test.dart` holds every production caller to it.
AppL10n l10nFor(Locale? wanted) => lookupAppL10n(resolveSupportedLocale(wanted));
