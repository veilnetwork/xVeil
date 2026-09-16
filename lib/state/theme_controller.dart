// Which look this profile wears.
//
// PER PROFILE, for the reason the language is (audit XV-15): a decoy that
// opens in the theme the real profile chose is a tell of exactly the kind
// somebody comparing the two would read. The choice lives in the same
// identity-scoped preference space, so "clear all data" takes it with
// everything else.
//
// Custom themes are kept beside the choice rather than inside the container:
// a theme is a preference, not a secret, and keeping it in prefs means the
// look is right from the first frame — before any password is typed, which is
// the one screen a container-stored theme could never paint.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/theme_spec.dart';
import 'identity_scoped_prefs.dart';
import 'providers.dart';

String get _kChosenKey => identityScopedPrefKey('theme_chosen');
String get _kCustomKey => identityScopedPrefKey('theme_custom');

/// Everything this profile can choose between: what ships with the app, then
/// what this person made or was given.
class ThemeChoices {
  const ThemeChoices({required this.chosen, required this.custom});

  final ThemeSpec chosen;
  final List<ThemeSpec> custom;

  List<ThemeSpec> get all => [...kBuiltInThemes, ...custom];
}

class ThemeController extends Notifier<ThemeChoices> {
  @override
  ThemeChoices build() {
    _load();
    return ThemeChoices(chosen: kDefaultTheme, custom: const []);
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      final custom = <ThemeSpec>[];
      final raw = prefs.getString(_kCustomKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is! Map) continue;
            final spec = ThemeSpec.fromJson(entry);
            if (spec != null) custom.add(spec);
          }
        }
      }
      final chosenId = prefs.getString(_kChosenKey);
      final all = [...kBuiltInThemes, ...custom];
      final chosen = all.firstWhere(
        (t) => t.id == chosenId,
        // A theme that was deleted, or one this build no longer ships, leaves
        // the app looking the way it always did rather than not looking like
        // anything.
        orElse: () => kDefaultTheme,
      );
      state = ThemeChoices(chosen: chosen, custom: custom);
    } catch (_) {
      // No prefs (widget tests, a profile store that would not open): the
      // default look is a complete answer.
    }
  }

  Future<void> choose(ThemeSpec spec) async {
    state = ThemeChoices(chosen: spec, custom: state.custom);
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setString(_kChosenKey, spec.id);
    } catch (_) {
      // The look changed for this session; it will not survive a restart, and
      // that is a better failure than refusing to change at all.
    }
  }

  /// Keep a theme somebody made or was given, and wear it.
  ///
  /// Replaces by id, so importing an updated copy of a theme you already have
  /// changes it rather than leaving two rows that look identical.
  Future<void> addCustom(ThemeSpec spec) async {
    final custom = [
      for (final t in state.custom)
        if (t.id != spec.id) t,
      spec,
    ];
    state = ThemeChoices(chosen: spec, custom: custom);
    await _persistCustom(custom, chosen: spec);
  }

  Future<void> removeCustom(String id) async {
    final custom = [
      for (final t in state.custom)
        if (t.id != id) t,
    ];
    // Wearing a theme that has just been deleted would leave the app in a look
    // nothing on the screen points at.
    final chosen = state.chosen.id == id ? kDefaultTheme : state.chosen;
    state = ThemeChoices(chosen: chosen, custom: custom);
    await _persistCustom(custom, chosen: chosen);
  }

  Future<void> _persistCustom(
    List<ThemeSpec> custom, {
    required ThemeSpec chosen,
  }) async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setString(
        _kCustomKey,
        jsonEncode([for (final t in custom) t.toJson()]),
      );
      await prefs.setString(_kChosenKey, chosen.id);
    } catch (_) {
      // Same reasoning as `choose`.
    }
  }
}

final themeProvider = NotifierProvider<ThemeController, ThemeChoices>(
  ThemeController.new,
);
