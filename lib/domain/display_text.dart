/// Text that arrived from somewhere else and is about to be SHOWN.
///
/// A file name, a contact's label, the name on a shared exit. The rule is the
/// same for all of them because the risk is: a person reads it and decides
/// something, and whoever sent it chose the characters.
///
/// Two classes are removed.
///
/// Reordering controls — the bidi overrides and isolates — change what is read
/// without changing what it is. `photo\u202Egnp.exe` renders as
/// `photoexe.png`; the same trick renames an exit node in a list.
///
/// Invisible formatting — zero-width spaces, the byte-order mark, a soft
/// hyphen — makes two different strings look like one, and a person choosing
/// between them cannot.
///
/// U+200C and U+200D are deliberately NOT removed. They join and separate
/// letters in Persian, Hindi and emoji sequences, they reorder nothing, and
/// stripping them breaks names simply written in another script.
library;

import 'package:characters/characters.dart';

/// Reordering and invisible formatting. See the library note.
final RegExp invisibleOrReordering = RegExp(
  '[\\u061C\\u200B\\u200E\\u200F\\u202A-\\u202E'
  '\\u2060-\\u2064\\u2066-\\u2069\\u00AD\\uFEFF]',
);

/// C0 controls and DEL: a newline in a one-line list item is a name that
/// rewrites the rows under it.
final RegExp _controls = RegExp(r'[\x00-\x1f\x7f]');

/// [text] made safe to show, and no longer than [maxChars] characters.
///
/// Replaced with `_` rather than removed, for the same reason a separator is:
/// two names that differ only by something invisible must not collapse into
/// one thing on the screen.
String safeDisplayLabel(String text, {required int maxChars}) {
  var out = text
      .replaceAll(_controls, '_')
      .replaceAll(invisibleOrReordering, '_')
      .trim();
  if (out.characters.length > maxChars) {
    out = out.characters.take(maxChars).toString().trim();
  }
  return out;
}
