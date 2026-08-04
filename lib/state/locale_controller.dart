import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
