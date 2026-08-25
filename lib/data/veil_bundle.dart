// One container, two kinds: .veiltranslate for a language pair and .veilaudio
// for the speech model. One file a person can hand to another, either way.
//
// A language pair is five files. Asking someone to move five files into a
// directory with the right name is asking them to make the mistake this app
// then has to detect — four files plus a missing target.spm is not a partial
// model, it is a directory that translates into nonsense the moment the fifth
// arrives from a different pair. The speech model is a single file and needs
// no container at all; it gets one anyway, because two nearly-identical
// formats would be two readers, two sets of bounds checks, and eventually one
// of them missing a fix the other got.
//
// The kind is IN the manifest, not in the extension. A filename is a hint
// anybody can change; the reader believes the manifest and checks the files
// against the list that kind is allowed to carry.
//
// ## Why not a zip
//
// Because the sender is not trusted. A .veiltranslate can arrive as an
// ordinary file in a chat, which is the point — it needs no new transport —
// and that means the parser is exposed to whatever someone chooses to send.
// A general archive format brings path traversal, symlink entries, nested
// archives and decompression bombs, none of which this needs.
//
// So the format is deliberately poor:
//
//   "VEILTR1\n"            8 bytes, so a wrong file is refused immediately
//   (the magic is shared: the kind is a manifest field, not a file format)
//   uint32 big-endian      manifest length, bounded
//   manifest               UTF-8 JSON
//   blobs                  raw bytes, in manifest order, no compression
//
// There are no paths in it. Names are checked against the fixed list its kind
// allows,
// so nothing can be written anywhere unexpected — not because the code is
// careful, but because the format cannot express it. Nothing is compressed,
// so there is no bomb: the declared sizes must add up to the file's actual
// length, which is checked before a byte is written.
//
// ## What this does NOT prove
//
// The hashes establish that the bytes are the bytes the manifest describes.
// They establish nothing about WHO made them: a substituted model with a
// manifest of its own passes every check here. A model decides what the app
// claims another person said, so an import from a chat must name where it came
// from and must never be silent. That is a decision for the UI; this layer
// refuses to make it look settled.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'translation_model_store.dart';

const List<int> _magic = [0x56, 0x45, 0x49, 0x4c, 0x54, 0x52, 0x31, 0x0a]; // VEILTR1\n

/// Longer than any honest manifest for five files, short enough that a
/// hostile one cannot make us allocate.
const int kMaxManifestBytes = 64 * 1024;

/// A language pair for the translation engine.
const String kBundleTranslate = 'translate';

/// The speech model the transcriber loads. One file, not a set — but it
/// travels the same way, so a person hands over one file either way and the
/// same reader checks both.
const String kBundleSpeech = 'speech';

const List<String> kVeilBundleKinds = [kBundleTranslate, kBundleSpeech];

/// The file extension each kind travels under.
///
/// Here, beside the kinds, because two copies of a name is how the exporter
/// and the receiver end up disagreeing about what a file is called — and a
/// bundle nobody recognises is a bundle nobody installs.
const String kTranslateBundleExt = '.veiltranslate';
const String kSpeechBundleExt = '.veilaudio';
const Map<String, String> kBundleExtensions = {
  kBundleTranslate: kTranslateBundleExt,
  kBundleSpeech: kSpeechBundleExt,
};

/// What a speech bundle may contain. Named here rather than imported from the
/// whisper store so that the READER — which parses input from a stranger —
/// does not depend on the app's model layer.
const List<String> kSpeechFiles = ['ggml-base-q5_1.bin'];

/// No pair is anywhere near this. It exists so a declared size cannot ask for
/// an allocation before the arithmetic below has been checked.
///
/// A FORMAT bound, not a product one: it says what the arithmetic in this file
/// can be trusted with. What a device is willing to receive is a separate,
/// much smaller question — see [kMaxReceivedBundleBytes].
const int kMaxBundleBytes = 2 * 1024 * 1024 * 1024;

/// The largest bundle this app will accept from a correspondent.
///
/// The format bound above is 2 GiB, and a phone asked to install a 2 GiB
/// bundle does not refuse it — it dies. The real sizes are two orders of
/// magnitude below: the speech model is one ~57 MB file, and a translation
/// pair is a few hundred MB at the outside. 512 MiB leaves room for both to
/// grow several times over while staying inside what a mid-range phone can
/// write to its own temporary directory (report14 X14-M2).
///
/// This is a receiving policy. A bundle the person picked from their own disk
/// is not bound by it — they chose it, they know where it came from, and the
/// installer streams either way.
const int kMaxReceivedBundleBytes = 512 * 1024 * 1024;

class VeilBundleFile {
  const VeilBundleFile({
    required this.name,
    required this.bytes,
    required this.sha256,
  });
  final String name;
  final int bytes;
  final String sha256;
}

/// What a bundle says about itself, read without unpacking it.
class VeilBundleInfo {
  const VeilBundleInfo({
    required this.kind,
    required this.pair,
    required this.files,
    required this.bodyOffset,
  });

  /// Where the blobs start, from the manifest THIS reading validated.
  ///
  /// Carried rather than recomputed: installBundle used to read the header a
  /// second time to find it, so the bytes it validated and the bytes it
  /// extracted came from two separate reads of a file somebody else supplied.
  /// The per-blob hashes would have caught a swap, but a parser for untrusted
  /// input should not have two answers to the same question in the first
  /// place.
  final int bodyOffset;

  /// [kBundleTranslate] or [kBundleSpeech].
  final String kind;

  /// The direction, for a translation bundle. Null for a speech bundle: one
  /// model transcribes every language it knows, so there is no pair to name.
  final TranslationPair? pair;
  final List<VeilBundleFile> files;

  /// What a person should see before deciding: "ru → en" or "speech".
  String get label => pair?.id ?? kind;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes);
}

class VeilBundleException implements Exception {
  VeilBundleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read the header and manifest. Cheap: it does not hash anything, so a UI can
/// say "ru → en, 79 MB — install?" before committing to the work.
///
/// Throws [VeilBundleException] with a reason a person could act on.
/// Every check here has to survive a file chosen by someone else.
Future<VeilBundleInfo> inspectBundle(File bundle) async {
  // Every filesystem touch, not just the parsing. A file that has been moved,
  // deleted or is unreadable throws PathNotFoundException or FileSystemException
  // from dart:io, and those are NOT VeilBundleException — so they went
  // straight past installBundle's handler and out through the controller. A
  // person picking a file that has since vanished got a crash where they
  // should have got a sentence.
  final int length;
  try {
    length = await bundle.length();
  } on FileSystemException catch (e) {
    throw VeilBundleException('cannot read the file: ${e.osError?.message ?? e.message}');
  }
  if (length < _magic.length + 4) {
    throw VeilBundleException('not a veil bundle (too short)');
  }

  final Uint8List head;
  try {
    head = await _read(bundle, 0, _magic.length + 4);
  } on FileSystemException catch (e) {
    throw VeilBundleException('cannot read the file: ${e.osError?.message ?? e.message}');
  }
  for (var i = 0; i < _magic.length; i++) {
    if (head[i] != _magic[i]) {
      throw VeilBundleException('not a veil bundle (bad header)');
    }
  }
  final manifestLength = ByteData.sublistView(head, _magic.length).getUint32(0);
  if (manifestLength == 0 || manifestLength > kMaxManifestBytes) {
    throw VeilBundleException(
      'the manifest claims $manifestLength bytes, which is not credible',
    );
  }
  final manifestStart = _magic.length + 4;
  if (manifestStart + manifestLength > length) {
    throw VeilBundleException('the file ends inside its own manifest');
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(await _read(bundle, manifestStart, manifestLength)),
    );
  } on Object {
    throw VeilBundleException('the manifest is not readable JSON');
  }
  if (decoded is! Map) {
    throw VeilBundleException('the manifest is not an object');
  }
  if (decoded['format'] != 1) {
    throw VeilBundleException(
      'this bundle is format ${decoded['format']}, and this build reads format 1',
    );
  }

  // One format, two kinds, rather than a second nearly-identical container
  // for the speech model. Two formats would be two readers, two sets of
  // bounds checks, and eventually one of them missing a fix the other got —
  // which is the drift this repository paid for twice this week, in build
  // arguments and in a download loop.
  final kind = decoded['kind'];
  if (kind is! String || !kVeilBundleKinds.contains(kind)) {
    throw VeilBundleException(
      'the manifest does not say what kind of bundle this is '
      '(expected one of ${kVeilBundleKinds.join(", ")})',
    );
  }

  TranslationPair? pair;
  if (kind == kBundleTranslate) {
    final from = decoded['from'];
    final to = decoded['to'];
    final code = RegExp(r'^[a-z]{2,3}$');
    if (from is! String || to is! String ||
        !code.hasMatch(from) || !code.hasMatch(to)) {
      throw VeilBundleException('the manifest does not name a language pair');
    }
    if (from == to) {
      throw VeilBundleException('a bundle from $from to $to translates nothing');
    }
    pair = TranslationPair(from, to);
  } else if (decoded.containsKey('from') || decoded.containsKey('to')) {
    // A speech bundle naming a language pair is either mislabelled or trying
    // to be read as two things at once. Refused rather than ignored.
    throw VeilBundleException('a $kind bundle must not name a language pair');
  }

  final allowed = kind == kBundleTranslate ? kPairFiles : kSpeechFiles;
  final rawFiles = decoded['files'];
  if (rawFiles is! List || rawFiles.isEmpty) {
    throw VeilBundleException('the manifest lists no files');
  }

  final files = <VeilBundleFile>[];
  final seen = <String>{};
  var total = 0;
  for (final entry in rawFiles) {
    if (entry is! Map) {
      throw VeilBundleException('a file entry is not an object');
    }
    final name = entry['name'];
    final bytes = entry['bytes'];
    final hash = entry['sha256'];
    // The allowlist IS the path safety. There are no directories in this
    // format and no name outside these five is accepted, so nothing can be
    // written where it was not meant to go.
    if (name is! String || !allowed.contains(name)) {
      throw VeilBundleException('unexpected file in the bundle: $name');
    }
    if (!seen.add(name)) {
      throw VeilBundleException('$name appears twice');
    }
    if (bytes is! int || bytes < 0 || bytes > kMaxBundleBytes) {
      throw VeilBundleException('$name declares an impossible size');
    }
    if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw VeilBundleException('$name has no usable sha256');
    }
    total += bytes;
    if (total > kMaxBundleBytes) {
      throw VeilBundleException('the bundle declares more than 2 GiB');
    }
    files.add(VeilBundleFile(name: name, bytes: bytes, sha256: hash));
  }

  final missing = allowed.where((f) => !seen.contains(f)).toList();
  if (missing.isNotEmpty) {
    // Refused here rather than after unpacking: an incomplete pair on disk is
    // the state the rest of the app has to keep detecting.
    throw VeilBundleException(
      'the bundle is missing ${missing.join(", ")} — an incomplete set '
      'cannot be used, and half of one is worse than none',
    );
  }

  final expected = manifestStart + manifestLength + total;
  if (expected != length) {
    // Both directions matter. Short means truncated; long means something is
    // riding along that nothing will ever check.
    throw VeilBundleException(
      'the bundle should be $expected bytes and is $length',
    );
  }

  return VeilBundleInfo(
    kind: kind,
    pair: pair,
    files: files,
    bodyOffset: manifestStart + manifestLength,
  );
}

class VeilBundleInstall {
  const VeilBundleInstall.ok(this.path, this.pair) : error = null;
  const VeilBundleInstall.failed(this.error) : path = null, pair = null;

  final String? path;
  final TranslationPair? pair;
  final String? error;
  bool get succeeded => path != null;
}

/// Verify a bundle and put the pair where the app looks for it.
///
/// Nothing is visible until everything has been verified. The files land in a
/// Put back models an interrupted install left aside.
///
/// [installBundle] replaces a pair with two renames — the old one out to
/// `.replacing-<id>`, the new one in — and a crash between them leaves a
/// complete, working model under a name nothing looks for: the pair reads as
/// uninstalled while its bytes are right there.
///
/// Restores any such directory whose destination is missing and returns the
/// pair ids it brought back. Safe to call wherever the models root is read:
/// with the destination present the leftover is debris from a finished
/// replace, and it is left for the next install to clear.
List<String> recoverInterruptedInstalls(Directory modelsRoot) {
  if (!modelsRoot.existsSync()) return const [];
  final restored = <String>[];
  for (final entry in modelsRoot.listSync().whereType<Directory>()) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (!name.startsWith('.replacing-')) continue;
    final id = name.substring('.replacing-'.length);
    final destination = Directory('${modelsRoot.path}/$id');
    if (destination.existsSync()) continue;
    try {
      entry.renameSync(destination.path);
      restored.add(id);
    } on FileSystemException {
      // Best-effort: one we cannot move is left where it is rather than
      // removed, because it may still be the only copy.
    }
  }
  return restored;
}

/// temporary directory beside the destination and are moved into place at the
/// end, so an import interrupted at any point leaves either the previous model
/// or nothing — never a directory with four files in it.
///
/// "The previous model" may be sitting under `.replacing-<id>` when the
/// interruption landed between the two renames; see
/// [recoverInterruptedInstalls], which this calls for on the way in.
Future<VeilBundleInstall> installBundle(
  File bundle, {
  required Directory modelsRoot,
  void Function(double progress)? onProgress,
}) async {
  final VeilBundleInfo info;
  try {
    info = await inspectBundle(bundle);
  } on VeilBundleException catch (e) {
    return VeilBundleInstall.failed(e.message);
  }

  // A translation pair becomes its own directory; the speech model is a single
  // file that lives in the root the caller gave. Staging is keyed on the label
  // either way, so two imports of different things cannot collide.
  final staging = Directory('${modelsRoot.path}/.incoming-${info.label}');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  try {
    var offset = info.bodyOffset;
    var written = 0;
    final total = info.totalBytes;

    for (final entry in info.files) {
      final digest = _DigestSink();
      final input = sha256.startChunkedConversion(digest);
      final sink = File('${staging.path}/${entry.name}').openWrite();
      var remaining = entry.bytes;
      try {
        await for (final chunk in bundle.openRead(offset, offset + entry.bytes)) {
          sink.add(chunk);
          input.add(chunk);
          remaining -= chunk.length;
          written += chunk.length;
          if (onProgress != null && total > 0) {
            onProgress(written >= total ? 1 : written / total);
          }
        }
      } finally {
        await sink.close();
      }
      input.close();
      if (remaining != 0) {
        return VeilBundleInstall.failed(
          '${entry.name} is ${entry.bytes - remaining} bytes, not ${entry.bytes}',
        );
      }
      final actual = digest.digest.toString();
      if (actual != entry.sha256) {
        // Named, because "the bundle is corrupt" tells a person nothing about
        // whether to retry the transfer or distrust the sender.
        return VeilBundleInstall.failed(
          '${entry.name} does not match its hash',
        );
      }
      offset += entry.bytes;
    }

    if (info.pair == null) {
      // One file, into the root as it is. The move is per file and still last,
      // so an interrupted import leaves the previous model rather than a
      // half-written one.
      modelsRoot.createSync(recursive: true);
      for (final entry in info.files) {
        File('${staging.path}/${entry.name}')
            .renameSync('${modelsRoot.path}/${entry.name}');
      }
      return VeilBundleInstall.ok(modelsRoot.path, null);
    }

    final destination = Directory('${modelsRoot.path}/${info.pair!.id}');
    final displaced = Directory('${modelsRoot.path}/.replacing-${info.pair!.id}');
    // A leftover `.replacing-*` means one of two things, and they need
    // opposite treatment.
    //
    // With the destination present it is debris from a completed replace, and
    // deleting it is right. With the destination ABSENT it is the only copy of
    // a working model: a previous install was interrupted between its two
    // renames — the old pair moved aside, the new one not yet moved in. This
    // used to delete it either way, so a power loss during an install left the
    // model invisible to `refresh` (which lists only `xx-yy` directories) and
    // the next attempt destroyed it before trying. If that attempt then failed,
    // the person had neither version.
    if (displaced.existsSync()) {
      if (destination.existsSync()) {
        displaced.deleteSync(recursive: true);
      } else {
        displaced.renameSync(destination.path);
      }
    }
    final replacing = destination.existsSync();
    if (replacing) destination.renameSync(displaced.path);
    try {
      staging.renameSync(destination.path);
    } on Object {
      // Put back what was there. An import that fails must not also destroy a
      // model that worked.
      if (replacing) displaced.renameSync(destination.path);
      rethrow;
    }
    if (replacing) displaced.deleteSync(recursive: true);
    return VeilBundleInstall.ok(destination.path, info.pair);
  } on FileSystemException catch (e) {
    return VeilBundleInstall.failed(
      'cannot read the file: ${e.osError?.message ?? e.message}',
    );
  } on Object catch (error) {
    return VeilBundleInstall.failed('$error');
  } finally {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}

/// Write a pair directory out as a bundle. Used by tooling and by the tests
/// that read it back — a format with only a reader is a format nobody has
/// checked round-trips.
/// Write a set of files out as a bundle. Used by tooling and by the tests that
/// read it back — a format with only a reader is a format nobody has checked
/// round-trips.
///
/// [pair] is required for a translation bundle and must be null for a speech
/// one; the reader refuses the mismatch either way, and this refuses to
/// produce it.
Future<void> writeBundle({
  required Directory sourceDir,
  required File out,
  String kind = kBundleTranslate,
  TranslationPair? pair,
}) async {
  if (kind == kBundleTranslate && pair == null) {
    throw VeilBundleException('a translation bundle must name its direction');
  }
  if (kind != kBundleTranslate && pair != null) {
    throw VeilBundleException('a $kind bundle must not name a language pair');
  }
  final names = kind == kBundleTranslate ? kPairFiles : kSpeechFiles;

  final entries = <Map<String, Object>>[];
  for (final name in names) {
    final file = File('${sourceDir.path}/$name');
    if (!file.existsSync()) {
      throw VeilBundleException('$name is missing from ${sourceDir.path}');
    }
    final bytes = await file.readAsBytes();
    entries.add({
      'name': name,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  final manifest = utf8.encode(
    jsonEncode({
      'format': 1,
      'kind': kind,
      if (pair != null) 'from': pair.from,
      if (pair != null) 'to': pair.to,
      'files': entries,
    }),
  );

  final sink = out.openWrite();
  try {
    sink.add(_magic);
    final length = ByteData(4)..setUint32(0, manifest.length);
    sink.add(length.buffer.asUint8List());
    sink.add(manifest);
    for (final name in names) {
      await sink.addStream(File('${sourceDir.path}/$name').openRead());
    }
  } finally {
    await sink.close();
  }
}

Future<Uint8List> _read(File file, int start, int length) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(start, start + length)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// The one digest a chunked sha256 emits when it closes. Local rather than
/// package:convert's AccumulatorSink, which is not a dependency of this app.
class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
