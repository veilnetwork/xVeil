import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _kLocaleKey = 'locale';

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
