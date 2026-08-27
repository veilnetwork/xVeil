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

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:characters/characters.dart';

import 'display_text.dart';

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
/// The SAME set the rest of the app uses on text somebody else chose — see
/// [invisibleOrReordering]. It was written out again here, in a different
/// notation, for the same reason and with the same code points: the risk is
/// the same one. Two spellings of one rule is how one of them gets fixed
/// alone, which is the shape three separate findings in this tree already
/// took.
///
/// A name is read by a person before they decide to open it, and these change
/// what they read without changing what it is. `photo\u202Egnp.exe` renders as
/// `photoexe.png` — the extension a person sees is not the one the system
/// uses, and the name arrives from whoever sent the file.

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
  if (invisibleOrReordering.hasMatch(name)) return false;
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
      .replaceAll(invisibleOrReordering, '_')
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
    final candidate = _fitSuffixed(dir, stem, ' ($n)', ext);
    if (!taken(candidate)) return candidate;
  }
  // A thousand collisions on one name. Returning the plain one — which this
  // has just established is TAKEN — handed the caller a path it would
  // overwrite, which is the one thing this exists to prevent (report16 XV-04).
  //
  // A random tail instead. It is ugly, and it is a name nobody chose, but it
  // is not somebody's file.
  for (var attempt = 0; attempt < 8; attempt++) {
    final tag = _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
    final candidate = _fitSuffixed(dir, stem, ' ($tag)', ext);
    if (!taken(candidate)) return candidate;
  }
  // Eight random 32-bit tails all taken is not a filesystem anybody has. The
  // last one stands rather than a name known to be somebody else's.
  return _fitSuffixed(
    dir,
    stem,
    ' (${_random.nextInt(0x100000000).toRadixString(16)})',
    ext,
  );
}

final _random = Random.secure();

/// `<dir>/<stem><suffix><ext>`, with the STEM trimmed so the whole leaf still
/// fits a filesystem component.
///
/// The suffix and the extension are what must survive: a name cut to the byte
/// bound before the suffix is added comes back over it, and the disambiguating
/// part is the first thing an over-long name loses — which turns two different
/// files back into one.
String _fitSuffixed(String dir, String stem, String suffix, String ext) {
  final tail = utf8.encode(suffix + ext).length;
  var head = stem;
  while (utf8.encode(head).length + tail > maxFileNameBytes) {
    if (head.isEmpty) break;
    head = head.substring(
      0,
      head.characters.length - 1 < head.length
          ? head.length - head.characters.last.length
          : 0,
    );
  }
  return '$dir/${_trimTrailing(head)}$suffix$ext';
}
