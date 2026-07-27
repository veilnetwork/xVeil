import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';

/// The speech model, fetched on demand instead of shipped in the build.
///
/// The model is 57 MiB and does not compress — bundling it was 63% of the
/// Android download (89.7 MiB against 32.7 MiB without). Most people never
/// transcribe anything, so most of what they downloaded was a feature they
/// did not use.
///
/// It is stored ONCE FOR THE WHOLE APP, in the support directory root rather
/// than under `profiles/<name>/`: it is a static artifact identical for
/// everyone, carries nothing about the person, and re-downloading 57 MiB per
/// profile would be absurd. This is also where the existing Android and Linux
/// lookups already probe, so a downloaded model is found by the same code that
/// used to find a bundled one.
///
/// What the download must not do is take whatever bytes arrive. The expected
/// size and SHA-256 are pinned here, matching the values the Android packaging
/// step has always verified; anything else is discarded. A model is data, not
/// code, but it is data that shapes what the app says a person said.
class WhisperModelStore {
  WhisperModelStore({
    Future<Directory> Function()? supportDirectory,
    HttpClient Function()? httpClient,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _httpClient = httpClient ?? HttpClient.new;

  final Future<Directory> Function() _supportDirectory;
  final HttpClient Function() _httpClient;

  static const fileName = 'ggml-base-q5_1.bin';

  /// Pinned by the Android packaging step since the model was bundled; the
  /// download inherits the same two checks rather than inventing weaker ones.
  static const expectedSha256 =
      '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898';
  static const expectedBytes = 59707625;

  /// Where the bytes come from. A build can point this somewhere the operator
  /// controls — the default is the canonical whisper.cpp distribution, and
  /// fetching it is a plain HTTPS request from the person's own address, which
  /// is worth knowing about in an app built to avoid exactly that.
  static const downloadUrl = String.fromEnvironment(
    'XVEIL_WHISPER_MODEL_URL',
    defaultValue:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin',
  );

  Future<File> _target() async =>
      File('${(await _supportDirectory()).path}/$fileName');

  /// The installed model, or null. Cheap: a size check, not a hash — the hash
  /// was verified before the file was ever given this name.
  Future<File?> installed() async {
    final file = await _target();
    if (!file.existsSync()) return null;
    if (file.lengthSync() != expectedBytes) return null;
    return file;
  }

  Future<bool> isInstalled() async => (await installed()) != null;

  /// Delete the model. The person gets 57 MiB back and loses transcription
  /// until they fetch it again; nothing else depends on it.
  Future<void> remove() async {
    final file = await _target();
    if (file.existsSync()) file.deleteSync();
    final part = File('${file.path}.part');
    if (part.existsSync()) part.deleteSync();
  }

  /// Fetch the model, reporting progress in 0..1 (or null while the server has
  /// not said how long it is).
  ///
  /// Downloads to `<name>.part` and renames only after both checks pass, so an
  /// interrupted or corrupted attempt can never be mistaken for a model: the
  /// real name is only ever given to bytes that earned it.
  Future<WhisperModelDownload> download({
    void Function(double? progress)? onProgress,
    Uri? from,
  }) async {
    final file = await _target();
    final part = File('${file.path}.part');
    final client = _httpClient();
    try {
      final request = await client.getUrl(from ?? Uri.parse(downloadUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        return WhisperModelDownload.failed(
          'server said ${response.statusCode}',
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = part.openWrite();
      Digest? digest;
      final hasher = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback(
          (digests) => digest = digests.single,
        ),
      );
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          if (onProgress != null) {
            onProgress(total > 0 ? received / total : null);
          }
        }
      } finally {
        await sink.close();
        hasher.close();
      }

      // Size first: it is the cheap half of the same question, and a truncated
      // download is the common failure while a wrong hash is the rare one.
      if (received != expectedBytes) {
        part.deleteSync();
        return WhisperModelDownload.failed(
          'expected $expectedBytes bytes, got $received',
        );
      }
      final actual = digest.toString();
      if (actual != expectedSha256) {
        part.deleteSync();
        return WhisperModelDownload.failed('checksum mismatch');
      }
      part.renameSync(file.path);
      devLog(() => 'xVeil[whisper]: model installed ($received bytes)');
      return WhisperModelDownload.ok(file.path);
    } on Object catch (error) {
      if (part.existsSync()) part.deleteSync();
      return WhisperModelDownload.failed('$error');
    } finally {
      client.close(force: true);
    }
  }
}

class WhisperModelDownload {
  const WhisperModelDownload.ok(this.path) : error = null;
  const WhisperModelDownload.failed(this.error) : path = null;

  final String? path;
  final String? error;

  bool get succeeded => path != null;
}
