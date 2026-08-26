// A name that arrived from somewhere else is a LABEL, not a path.
//
// The distinction is the whole of this file. `Message.fileName` is whatever
// the sender typed: it is shown in the chat, used to pick an icon, and offered
// as a default when the person saves the file. None of those need it to be a
// path, and one place treated it as one — the model-bundle install wrote
// `File('${stageDir.path}/$name')` and then deleted that file's PARENT
// recursively, so a name of `../something` both wrote outside the stage and
// took an unrelated directory down with it on cleanup (report14 X14-H1).
//
// So there are two operations here and they are not the same:
//
//  * [isSafeFileLabel] — a boundary predicate. A manifest whose name is not a
//    plain label is refused outright, because nothing this project sends
//    produces one (every sender takes the last path segment) and no honest
//    correspondent needs one.
//  * [safeFileLeaf] — a reduction, for the places that must produce SOME name
//    for a file the person is saving. It never fails and never returns
//    anything that can leave a directory.
//
// Neither is a substitute for the real rule: a received name must not decide
// where bytes land. Where the destination is ours to choose, choose it.
library;

import 'dart:io';

/// Longest name we accept or produce, in UTF-16 code units.
///
/// The common filesystem limit is 255 BYTES per component, which for non-Latin
/// names is fewer characters than this — so the leaf is additionally trimmed
/// to fit when encoded. This bound is the cheap one, applied first so a
/// megabyte of name never reaches the encoder.
const int maxFileNameChars = 255;

/// Bytes a single path component may occupy on the filesystems we target.
const int maxFileNameBytes = 255;

/// Characters that reorder or hide text without being visible themselves.
///
/// A name is read by a person before they decide to open it, and these change
/// what they read without changing what it is. `photo\u202Egnp.exe` renders as
/// `photoexe.png` — the extension a person sees is not the one the system
/// uses, and the name arrives from whoever sent the file.
///
/// The invisible ones are here for a second reason: two names that differ only
/// by a zero-width space look like one name, and a person choosing between
/// them cannot.
///
/// U+200C and U+200D are deliberately NOT here. They join and separate letters
/// in Persian, Hindi and emoji sequences, they reorder nothing, and stripping
/// them breaks names that are simply written in another script.
final RegExp _invisibleOrReordering = RegExp(
  r'[\u061C\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\u00AD\uFEFF]',
);

final RegExp _separatorOrControl = RegExp(r'[/\\]|[\x00-\x1f\x7f]');

/// True when [name] is a plain filename: no path in it, nothing a shell or a
/// filesystem reads as structure, and not one of the directory aliases.
///
/// Deliberately strict about `\` as well as `/`: it is a separator on Windows,
/// and a name carrying one is either hostile or already broken on half the
/// platforms this runs on.
bool isSafeFileLabel(String name) {
  if (name.isEmpty || name.length > maxFileNameChars) return false;
  if (name != name.trim()) return false;
  if (name == '.' || name == '..') return false;
  if (_invisibleOrReordering.hasMatch(name)) return false;
  return !_separatorOrControl.hasMatch(name);
}

/// Reduce any name — including a hostile one — to a single filesystem leaf.
///
/// Separators and control characters become `_` rather than disappearing, so
/// two different names cannot silently collapse into one. `.` and `..` are
/// replaced entirely: as leaves they name the directory itself and its parent,
/// which is the traversal this exists to stop, and there is nothing of the
/// original to preserve.
String safeFileLeaf(String? name, {String fallback = 'file'}) {
  var out = (name ?? '')
      .replaceAll(_separatorOrControl, '_')
      // Replaced rather than removed, for the same reason separators are: two
      // names that differ only by something invisible must not collapse into
      // one.
      .replaceAll(_invisibleOrReordering, '_')
      .trim();
  if (out.length > maxFileNameChars) out = out.substring(0, maxFileNameChars);
  out = _trimTrailing(_fitBytes(out));
  return out.isEmpty ? fallback : out;
}

/// Trailing dots and spaces are stripped by Windows on create, which turns
/// `evil. ` into `evil` — two names, one file. Done after the byte fit,
/// because the fit itself can leave a name ending in one.
String _trimTrailing(String value) {
  var out = value;
  while (out.isNotEmpty && (out.endsWith('.') || out.endsWith(' '))) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// Keep whole characters up to [maxFileNameBytes] of UTF-8.
///
/// Cutting by code unit would split a surrogate pair and leave half a
/// character, which some filesystems reject and others store unreadably.
String _fitBytes(String value) {
  var bytes = 0;
  final kept = StringBuffer();
  for (final rune in value.runes) {
    final width = _runeBytes(rune);
    if (bytes + width > maxFileNameBytes) break;
    bytes += width;
    kept.writeCharCode(rune);
  }
  return kept.toString();
}

int _runeBytes(int rune) => rune <= 0x7f
    ? 1
    : rune <= 0x7ff
    ? 2
    : rune <= 0xffff
    ? 3
    : 4;

/// `<dir>/<name>`, or `<dir>/<stem> (n)<ext>` when that is taken.
///
/// One copy, because there were two and a third place that needed it and did
/// not have it. A destination taken straight from a name means the file
/// already there is destroyed — silently, by a write that truncates, or by a
/// rename that replaces — and the name is usually not the person's own: it
/// came off a message, or out of a shared volume.
///
/// Bounded: past a small number of collisions something is wrong with the
/// caller, and returning the plain name lets the existing overwrite happen
/// rather than looping.
String uncontestedPath(
  String dir,
  String name, {
  bool Function(String path)? exists,
}) {
  final taken = exists ?? (path) => File(path).existsSync();
  if (!taken('$dir/$name')) return '$dir/$name';
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var n = 1; n <= 999; n++) {
    final candidate = '$dir/$stem ($n)$ext';
    if (!taken(candidate)) return candidate;
  }
  return '$dir/$name';
}
