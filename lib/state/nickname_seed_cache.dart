// The resume cache for nickname mining, and the ceiling it kept walking into.
//
// Mining a name accumulates 32-byte proof seeds until the target weight is
// reached; the set is saved after every chunk so a restart resumes instead of
// starting over. It used to be saved as ONE settings value, and a settings
// value must fit a single hidden-volume chunk — 4096 bytes less nonce and tag
// leaves 4068 of plaintext, and base64 adds a third on top, so one value holds
// roughly ninety seeds.
//
// Past that, every save threw `PayloadTooLarge`, and the throw came out of the
// mining loop and killed the claim: the person watched the work finish and got
// an error instead of a name (reported live on 2026-09-08, @HateError).
//
// So the cache is split across numbered values and, more importantly, it is
// ALLOWED TO FAIL. A cache that cannot be written costs a slower retry; a
// cache that throws costs the claim.
//
// Kept out of the controller so it can be tested against a store with the real
// ceiling — the controller itself needs the native miner and the network to do
// anything at all.

import 'dart:convert';
import 'dart:typed_data';

/// base64 characters per part.
///
/// A settings value has to fit one 4068-byte chunk, and the record's own key
/// and framing eat into that; 2048 leaves room to spare rather than sitting
/// against a ceiling whose exact overhead lives in another repository. Each
/// part carries 1536 bytes — 48 seeds.
const int kSeedPartChars = 2048;

/// How many parts the cache may use before it gives up on resuming.
///
/// Sixty-four parts is a little over three thousand seeds, far past what a
/// claim mines in practice. The bound exists so a runaway set fills neither
/// the container nor the settings namespace; past it, mining continues with no
/// resume point, which is the correct trade — it is only a cache.
const int kMaxSeedParts = 64;

/// Reads and writes the seed set through a settings store.
///
/// Takes the two operations rather than the whole storage port: this needs
/// exactly get and put, and a test that had to implement sixty other methods
/// to exercise a cache would not be written.
class NicknameSeedCache {
  NicknameSeedCache({
    required this.manifestKey,
    required this.get,
    required this.put,
    this.partChars = kSeedPartChars,
    this.maxParts = kMaxSeedParts,
  });

  final String manifestKey;
  final Future<String?> Function(String key) get;
  final Future<void> Function(String key, String value) put;
  final int partChars;
  final int maxParts;

  String _partKey(int i) => '$manifestKey.$i';

  /// The set saved for [name], or empty when there is nothing to resume.
  ///
  /// Anything unexpected — a missing part, a manifest from a half-finished
  /// save, a value written by a build that used the single-value layout and
  /// then outgrew it — answers "nothing to resume". This is a cache: mining
  /// again is slow, while reconstructing a WRONG set would publish a claim
  /// that does not verify.
  Future<Uint8List> load(String name) async {
    try {
      final raw = await get(manifestKey);
      if (raw == null || raw.isEmpty) return Uint8List(0);
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['name'] != name) return Uint8List(0);

      // The layout before the split, still on disk for anyone who mined with
      // an older build: read it, so an interrupted claim resumes across the
      // upgrade rather than starting from zero.
      final inline = m['seeds'] as String?;
      if (inline != null && inline.isNotEmpty) {
        return Uint8List.fromList(base64Decode(inline));
      }

      final count = (m['parts'] as num?)?.toInt() ?? 0;
      if (count <= 0) return Uint8List(0);
      final buf = StringBuffer();
      for (var i = 0; i < count; i++) {
        final part = await get(_partKey(i));
        if (part == null || part.isEmpty) return Uint8List(0);
        buf.write(part);
      }
      return Uint8List.fromList(base64Decode(buf.toString()));
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// Save [seeds] for [name]; returns the number of parts written, or null
  /// when the cache could not be kept.
  ///
  /// [previousParts] is what the last successful save used, so parts the new
  /// manifest no longer covers are emptied instead of being left where a
  /// later, shorter manifest could read them.
  ///
  /// The manifest is written LAST. A reader that sees a count must find every
  /// part behind it; the other order leaves a window in which the count
  /// promises data that is not there — and this runs after every mining chunk,
  /// so that window would be visited constantly.
  Future<int?> save(String name, Uint8List seeds, int previousParts) async {
    final encoded = base64Encode(seeds);
    final count = (encoded.length + partChars - 1) ~/ partChars;
    if (count > maxParts) return null;
    try {
      for (var i = 0; i < count; i++) {
        final start = i * partChars;
        var end = start + partChars;
        if (end > encoded.length) end = encoded.length;
        await put(_partKey(i), encoded.substring(start, end));
      }
      await put(manifestKey, jsonEncode({'name': name, 'parts': count}));
      for (var i = count; i < previousParts; i++) {
        await put(_partKey(i), '');
      }
      return count;
    } catch (_) {
      // The caller keeps mining without a resume point. Deliberately silent to
      // the person: they asked for a name, not for a report about a cache.
      return null;
    }
  }

  /// Forget the cache, including the [parts] the last manifest covered.
  Future<void> clear(int parts) async {
    try {
      await put(manifestKey, jsonEncode(<String, dynamic>{}));
      for (var i = 0; i < parts; i++) {
        await put(_partKey(i), '');
      }
    } catch (_) {
      // Same reasoning as the save: a cache that will not clear must not take
      // the claim down with it.
    }
  }
}
