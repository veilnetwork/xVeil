// The .veiltranslate container: one file a person can hand to another.
//
// A language pair is five files. Asking someone to move five files into a
// directory with the right name is asking them to make the mistake this app
// then has to detect — four files plus a missing target.spm is not a partial
// model, it is a directory that translates into nonsense the moment the fifth
// arrives from a different pair.
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
//   uint32 big-endian      manifest length, bounded
//   manifest               UTF-8 JSON
//   blobs                  raw bytes, in manifest order, no compression
//
// There are no paths in it. Names are checked against a fixed list of five,
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

/// No pair is anywhere near this. It exists so a declared size cannot ask for
/// an allocation before the arithmetic below has been checked.
const int kMaxBundleBytes = 2 * 1024 * 1024 * 1024;

class TranslationBundleFile {
  const TranslationBundleFile({
    required this.name,
    required this.bytes,
    required this.sha256,
  });
  final String name;
  final int bytes;
  final String sha256;
}

/// What a bundle says about itself, read without unpacking it.
class TranslationBundleInfo {
  const TranslationBundleInfo({required this.pair, required this.files});
  final TranslationPair pair;
  final List<TranslationBundleFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes);
}

class TranslationBundleException implements Exception {
  TranslationBundleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read the header and manifest. Cheap: it does not hash anything, so a UI can
/// say "ru → en, 79 MB — install?" before committing to the work.
///
/// Throws [TranslationBundleException] with a reason a person could act on.
/// Every check here has to survive a file chosen by someone else.
Future<TranslationBundleInfo> inspectBundle(File bundle) async {
  // Every filesystem touch, not just the parsing. A file that has been moved,
  // deleted or is unreadable throws PathNotFoundException or FileSystemException
  // from dart:io, and those are NOT TranslationBundleException — so they went
  // straight past installBundle's handler and out through the controller. A
  // person picking a file that has since vanished got a crash where they
  // should have got a sentence.
  final int length;
  try {
    length = await bundle.length();
  } on FileSystemException catch (e) {
    throw TranslationBundleException('cannot read the file: ${e.osError?.message ?? e.message}');
  }
  if (length < _magic.length + 4) {
    throw TranslationBundleException('not a .veiltranslate file (too short)');
  }

  final Uint8List head;
  try {
    head = await _read(bundle, 0, _magic.length + 4);
  } on FileSystemException catch (e) {
    throw TranslationBundleException('cannot read the file: ${e.osError?.message ?? e.message}');
  }
  for (var i = 0; i < _magic.length; i++) {
    if (head[i] != _magic[i]) {
      throw TranslationBundleException('not a .veiltranslate file (bad header)');
    }
  }
  final manifestLength = ByteData.sublistView(head, _magic.length).getUint32(0);
  if (manifestLength == 0 || manifestLength > kMaxManifestBytes) {
    throw TranslationBundleException(
      'the manifest claims $manifestLength bytes, which is not credible',
    );
  }
  final manifestStart = _magic.length + 4;
  if (manifestStart + manifestLength > length) {
    throw TranslationBundleException('the file ends inside its own manifest');
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(await _read(bundle, manifestStart, manifestLength)),
    );
  } on Object {
    throw TranslationBundleException('the manifest is not readable JSON');
  }
  if (decoded is! Map) {
    throw TranslationBundleException('the manifest is not an object');
  }
  if (decoded['format'] != 1) {
    throw TranslationBundleException(
      'this bundle is format ${decoded['format']}, and this build reads format 1',
    );
  }

  final from = decoded['from'];
  final to = decoded['to'];
  final code = RegExp(r'^[a-z]{2,3}$');
  if (from is! String || to is! String ||
      !code.hasMatch(from) || !code.hasMatch(to)) {
    throw TranslationBundleException('the manifest does not name a language pair');
  }
  if (from == to) {
    throw TranslationBundleException('a bundle from $from to $to translates nothing');
  }

  final rawFiles = decoded['files'];
  if (rawFiles is! List || rawFiles.isEmpty) {
    throw TranslationBundleException('the manifest lists no files');
  }

  final files = <TranslationBundleFile>[];
  final seen = <String>{};
  var total = 0;
  for (final entry in rawFiles) {
    if (entry is! Map) {
      throw TranslationBundleException('a file entry is not an object');
    }
    final name = entry['name'];
    final bytes = entry['bytes'];
    final hash = entry['sha256'];
    // The allowlist IS the path safety. There are no directories in this
    // format and no name outside these five is accepted, so nothing can be
    // written where it was not meant to go.
    if (name is! String || !kPairFiles.contains(name)) {
      throw TranslationBundleException('unexpected file in the bundle: $name');
    }
    if (!seen.add(name)) {
      throw TranslationBundleException('$name appears twice');
    }
    if (bytes is! int || bytes < 0 || bytes > kMaxBundleBytes) {
      throw TranslationBundleException('$name declares an impossible size');
    }
    if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw TranslationBundleException('$name has no usable sha256');
    }
    total += bytes;
    if (total > kMaxBundleBytes) {
      throw TranslationBundleException('the bundle declares more than 2 GiB');
    }
    files.add(TranslationBundleFile(name: name, bytes: bytes, sha256: hash));
  }

  final missing = kPairFiles.where((f) => !seen.contains(f)).toList();
  if (missing.isNotEmpty) {
    // Refused here rather than after unpacking: an incomplete pair on disk is
    // the state the rest of the app has to keep detecting.
    throw TranslationBundleException(
      'the bundle is missing ${missing.join(", ")} — an incomplete pair '
      'cannot translate, and half of one is worse than none',
    );
  }

  final expected = manifestStart + manifestLength + total;
  if (expected != length) {
    // Both directions matter. Short means truncated; long means something is
    // riding along that nothing will ever check.
    throw TranslationBundleException(
      'the bundle should be $expected bytes and is $length',
    );
  }

  return TranslationBundleInfo(
    pair: TranslationPair(from, to),
    files: files,
  );
}

class TranslationBundleInstall {
  const TranslationBundleInstall.ok(this.path, this.pair) : error = null;
  const TranslationBundleInstall.failed(this.error) : path = null, pair = null;

  final String? path;
  final TranslationPair? pair;
  final String? error;
  bool get succeeded => path != null;
}

/// Verify a bundle and put the pair where the app looks for it.
///
/// Nothing is visible until everything has been verified. The files land in a
/// temporary directory beside the destination and are moved into place at the
/// end, so an import interrupted at any point leaves either the previous model
/// or nothing — never a directory with four files in it.
Future<TranslationBundleInstall> installBundle(
  File bundle, {
  required Directory modelsRoot,
  void Function(double progress)? onProgress,
}) async {
  final TranslationBundleInfo info;
  try {
    info = await inspectBundle(bundle);
  } on TranslationBundleException catch (e) {
    return TranslationBundleInstall.failed(e.message);
  }

  final staging = Directory('${modelsRoot.path}/.incoming-${info.pair.id}');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  try {
    final manifestEnd = _magic.length + 4 + await _manifestLength(bundle);
    var offset = manifestEnd;
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
        return TranslationBundleInstall.failed(
          '${entry.name} is ${entry.bytes - remaining} bytes, not ${entry.bytes}',
        );
      }
      final actual = digest.digest.toString();
      if (actual != entry.sha256) {
        // Named, because "the bundle is corrupt" tells a person nothing about
        // whether to retry the transfer or distrust the sender.
        return TranslationBundleInstall.failed(
          '${entry.name} does not match its hash',
        );
      }
      offset += entry.bytes;
    }

    final destination = Directory('${modelsRoot.path}/${info.pair.id}');
    final displaced = Directory('${modelsRoot.path}/.replacing-${info.pair.id}');
    if (displaced.existsSync()) displaced.deleteSync(recursive: true);
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
    return TranslationBundleInstall.ok(destination.path, info.pair);
  } on FileSystemException catch (e) {
    return TranslationBundleInstall.failed(
      'cannot read the file: ${e.osError?.message ?? e.message}',
    );
  } on Object catch (error) {
    return TranslationBundleInstall.failed('$error');
  } finally {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}

/// Write a pair directory out as a bundle. Used by tooling and by the tests
/// that read it back — a format with only a reader is a format nobody has
/// checked round-trips.
Future<void> writeBundle({
  required Directory pairDir,
  required TranslationPair pair,
  required File out,
}) async {
  final entries = <Map<String, Object>>[];
  for (final name in kPairFiles) {
    final file = File('${pairDir.path}/$name');
    if (!file.existsSync()) {
      throw TranslationBundleException('$name is missing from ${pairDir.path}');
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
      'from': pair.from,
      'to': pair.to,
      'files': entries,
    }),
  );

  final sink = out.openWrite();
  try {
    sink.add(_magic);
    final length = ByteData(4)..setUint32(0, manifest.length);
    sink.add(length.buffer.asUint8List());
    sink.add(manifest);
    for (final name in kPairFiles) {
      await sink.addStream(File('${pairDir.path}/$name').openRead());
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

Future<int> _manifestLength(File file) async {
  final head = await _read(file, _magic.length, 4);
  return ByteData.sublistView(head).getUint32(0);
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
