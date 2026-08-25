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

/// Longest name we accept or produce, in UTF-16 code units.
///
/// The common filesystem limit is 255 BYTES per component, which for non-Latin
/// names is fewer characters than this — so the leaf is additionally trimmed
/// to fit when encoded. This bound is the cheap one, applied first so a
/// megabyte of name never reaches the encoder.
const int maxFileNameChars = 255;

/// Bytes a single path component may occupy on the filesystems we target.
const int maxFileNameBytes = 255;

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
  var out = (name ?? '').replaceAll(_separatorOrControl, '_').trim();
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
