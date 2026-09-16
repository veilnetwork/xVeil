// A look that can be carried between people, and cannot lie on the way.
//
// A theme arrives from somebody else. This app puts the sentences a person
// cannot afford to miss — "this password opens a container that is already
// here", "the words restore a DIFFERENT identity", "compaction drops what you
// do not name" — in the error colour, so a theme that could name every colour
// could name that one, and an interface where the warning looks like ordinary
// text is worse than an ugly one.
//
// The defence is the shape of the format rather than a check inside it: a
// theme carries a SEED and a brightness, Material 3 derives the scheme with
// its own contrast rules, and there is nowhere in the file to say what error
// looks like.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/theme_spec.dart';

void main() {
  const sample = ThemeSpec(
    id: 'mine',
    name: 'Evening',
    seed: Color(0xFF7B4A8A),
    dark: true,
  );

  group('carrying a theme between people', () {
    test('what goes out comes back', () {
      final back = ThemeSpec.parse(sample.toText());
      expect(back, sample);
    });

    test('it survives the way a copy actually travels', () {
      // Wrapped across lines by a chat, with a label in front — the same
      // packaging the recovery certificate learned to tolerate, because it is
      // the same clipboard and the same people.
      final text = sample.toText();
      final wrapped =
          'my xVeil theme:\n${text.substring(0, 20)}\n${text.substring(20)}\n';
      expect(ThemeSpec.parse(wrapped), sample);
    });

    test('anything that is not a theme is simply not one', () {
      for (final bad in [
        'hello',
        'xveil-theme:v1:',
        'xveil-theme:v1:!!!!',
        'xveil-recovery:v1:AAAA',
        '',
      ]) {
        expect(ThemeSpec.parse(bad), isNull, reason: '"$bad" was accepted');
      }
    });

    test('an enormous paste is refused before it is decoded', () {
      final huge = '$kThemePrefix${'A' * (kMaxThemeTextBytes + 1)}';
      expect(ThemeSpec.parse(huge), isNull);
    });
  });

  group('what a sender is not allowed to decide', () {
    test('a theme cannot make the interface translucent', () {
      // Alpha is ours. A transparent surface is a way to make text unreadable
      // without ever naming a colour that looks wrong in a list.
      final spec = ThemeSpec.fromJson({'c': '00ff8800', 'n': 'Ghost'});
      expect(spec, isNotNull);
      expect(spec!.seed.a, 1.0);
    });

    test('a name cannot draw outside its row', () {
      // Bidi overrides and control characters, which is how a name repaints
      // the line it sits in.
      final spec = ThemeSpec.fromJson({
        'c': 'ff8800',
        'n': 'Nice\u202Etheme \u200b',
      });
      expect(spec!.name, 'Nicetheme');
    });

    test('a name cannot push the rest of the row off the screen', () {
      final spec = ThemeSpec.fromJson({'c': 'ff8800', 'n': 'z' * 500});
      expect(spec!.name.length, kMaxThemeNameChars);
    });

    test('a nameless theme is named, not refused', () {
      final spec = ThemeSpec.fromJson({'c': 'ff8800'});
      expect(spec, isNotNull);
      expect(spec!.name, isNotEmpty);
    });

    test('a theme with no colour is not a theme', () {
      expect(ThemeSpec.fromJson({'n': 'Nothing'}), isNull);
      expect(ThemeSpec.fromJson({'c': 'not a colour'}), isNull);
    });
  });

  group('what ships with the app', () {
    test('the default is the look every install already had', () {
      expect(kDefaultTheme.id, 'veil-dark');
      expect(kDefaultTheme.seed.toARGB32(), const Color(0xFF1E8A7B).toARGB32());
      expect(
        kDefaultTheme.dark,
        isTrue,
        reason: 'somebody who never opens this screen must see no change',
      );
    });

    test('every built-in has its own id and a usable name', () {
      final ids = kBuiltInThemes.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'two themes share an id');
      for (final theme in kBuiltInThemes) {
        expect(theme.name.trim(), isNotEmpty);
        expect(theme.name.length, lessThanOrEqualTo(kMaxThemeNameChars));
      }
    });

    test('a built-in survives being shared and read back', () {
      for (final theme in kBuiltInThemes) {
        expect(ThemeSpec.parse(theme.toText()), theme);
      }
    });
  });
}
